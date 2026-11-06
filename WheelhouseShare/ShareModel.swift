import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications
import WheelhouseKit

@MainActor @Observable
final class ShareModel {
    enum Phase {
        case loading
        case ready(Kubeconfig)
        case failed(String)
        case saved(notified: Bool)
    }

    private(set) var phase: Phase = .loading
    private(set) var fileName: String?
    private var text: String?
    private(set) var saveError: String?

    private let providers: [NSItemProvider]
    private let finish: () -> Void
    private let cancel: () -> Void

    init(providers: [NSItemProvider], finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.providers = providers
        self.finish = finish
        self.cancel = cancel
    }

    func load() {
        // Drop an expired or stale pending item left by an earlier share that was never claimed.
        PendingKubeconfigStore().purgeIfStale()
        Task {
            guard let provider = Self.firstMatching(providers) else {
                phase = .failed("Share a kubeconfig file or its text.")
                return
            }
            do {
                let loaded = try await Self.loadAttachment(ProviderBox(provider))
                let config = try KubeconfigParser.parse(loaded.text)
                text = loaded.text
                fileName = loaded.name
                phase = .ready(config)
            } catch let e as SharedAttachment.Failure {
                phase = .failed(SharedAttachment.message(for: e))
            } catch let e as KubeconfigError {
                let message: String = switch e {
                case .notYAML: "This isn’t valid YAML, so it can’t be a kubeconfig."
                case .notAKubeconfig: "This doesn’t look like a kubeconfig (no clusters or contexts)."
                case .empty: "The kubeconfig has no contexts."
                }
                phase = .failed(message)
            } catch {
                phase = .failed("This doesn’t look like a kubeconfig.")
            }
        }
    }

    func importInWheelhouse() {
        guard let text else { return }
        do {
            try PendingKubeconfigStore().save(text: text, name: fileName)
        } catch {
            saveError = "Couldn’t save the kubeconfig for Wheelhouse. Try again."
            return
        }
        saveError = nil
        phase = .saved(notified: false)
        Task { if await Self.postReadyNotification() { phase = .saved(notified: true) } }
    }

    func close() { finish() }
    func abort() { cancel() }

    // MARK: Loading

    /// `NSItemProvider` is thread-safe by contract but not annotated `Sendable`.
    private struct ProviderBox: @unchecked Sendable {
        let provider: NSItemProvider
        init(_ p: NSItemProvider) { provider = p }
    }

    /// Messaging apps may add a caption item next to the file: use the first attachment that is data or text, but not media or a PDF.
    nonisolated static func firstMatching(_ providers: [NSItemProvider]) -> NSItemProvider? {
        let excluded = [UTType.image, UTType.audiovisualContent, UTType.pdf]
        return providers.first { p in
            let ok = p.hasItemConformingToTypeIdentifier(UTType.data.identifier) || p.hasItemConformingToTypeIdentifier(UTType.text.identifier)
            return ok && !excluded.contains { p.hasItemConformingToTypeIdentifier($0.identifier) }
        }
    }

    private struct Loaded: Sendable { var text: String; var name: String? }

    /// File URL or data first, then plain text.
    nonisolated private static func loadAttachment(_ box: ProviderBox) async throws -> Loaded {
        let provider = box.provider
        let suggested = provider.suggestedName
        var failure: SharedAttachment.Failure = .unreadable
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do { return try await loadFileURL(box) } catch let e as SharedAttachment.Failure { failure = e }
        }
        if failure != .tooLarge, provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            do { return try await loadFileRepresentation(box, suggestedName: suggested) } catch let e as SharedAttachment.Failure { failure = e }
        }
        if failure != .tooLarge, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            do { return try await loadText(box) } catch let e as SharedAttachment.Failure { failure = e }
        }
        throw failure
    }

    nonisolated private static func loadFileURL(_ box: ProviderBox) async throws -> Loaded {
        let provider = box.provider
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Loaded, any Error>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item: NSSecureCoding?, _: Error?) in
                var found: URL?
                if let u = item as? URL { found = u }
                else if let d = item as? Data { found = URL(dataRepresentation: d, relativeTo: nil) }
                guard let url = found, url.isFileURL else { cont.resume(throwing: SharedAttachment.Failure.unreadable); return }
                do { cont.resume(returning: Loaded(text: try SharedAttachment.read(fileURL: url), name: url.lastPathComponent)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func loadFileRepresentation(_ box: ProviderBox, suggestedName: String?) async throws -> Loaded {
        let provider = box.provider
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Loaded, any Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                // The temporary file only exists inside this handler.
                guard let url else { cont.resume(throwing: SharedAttachment.Failure.unreadable); return }
                do { cont.resume(returning: Loaded(text: try SharedAttachment.read(fileURL: url), name: suggestedName ?? url.lastPathComponent)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func loadText(_ box: ProviderBox) async throws -> Loaded {
        let provider = box.provider
        let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.text.identifier
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Loaded, any Error>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { (item: NSSecureCoding?, _: Error?) in
                do {
                    let text: String
                    if let s = item as? String { text = try SharedAttachment.decode(text: s) }
                    else if let s = item as? NSString { text = try SharedAttachment.decode(text: s as String) }
                    else if let d = item as? Data { text = try SharedAttachment.decode(d) }
                    else if let u = item as? URL, u.isFileURL { text = try SharedAttachment.read(fileURL: u) }
                    else { throw SharedAttachment.Failure.unreadable }
                    cont.resume(returning: Loaded(text: text, name: "Shared text"))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: Notification

    /// Posts only when the user already allowed notifications for Wheelhouse; the extension never asks for permission.
    nonisolated private static func postReadyNotification() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Kubeconfig ready to import"
        content.body = "Tap to finish importing in Wheelhouse."
        content.sound = .default
        content.userInfo = ["url": DeepLink.importURL.absoluteString]
        let request = UNNotificationRequest(identifier: "com.ahmadrezaei.wheelhouse.pending-kubeconfig", content: content, trigger: nil)
        return (try? await center.add(request)) != nil
    }
}
