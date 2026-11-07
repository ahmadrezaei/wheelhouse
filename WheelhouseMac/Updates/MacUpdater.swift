import AppKit
import Combine
import Sparkle
import SwiftUI
import WheelhouseDesktop

/// The release channel the user follows. Stable is the default; Beta also receives items tagged `sparkle:channel` "beta".
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta
    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }
    static let defaultsKey = "WHUpdateChannel"
    static var stored: UpdateChannel {
        UpdateChannel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .stable
    }
}

/// Supplies the channel to Sparkle. Kept apart from `MacUpdater` so the controller can be created with its delegate in one step.
final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.stored == .beta ? ["beta"] : []
    }
}

/// Owns the Sparkle updater (ARCHITECTURE-MAC section 2.5).
///
/// The updater starts only when `SUFeedURL` is non-empty AND the development safety gate is off. Debug and Profile have no feed,
/// and a local Release build has the feed but the gate stays on, so a development build never checks for, downloads or installs
/// an update. `SUShowReleaseNotes` is false (no WebView): Sparkle's alert offers a Release Notes button that opens the notes page
/// in the default browser. The app is not sandboxed, so none of Sparkle's XPC installer services are embedded.
@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()

    /// True when this build is allowed to talk to the update feed.
    let feedIsSet: Bool
    private let delegate = UpdateChannelDelegate()
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false
    private var observation: AnyCancellable?

    static var configuredFeedIsSet: Bool {
        DevSafetyPolicy.current.shouldStartUpdater(feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    }

    private init() {
        let set = Self.configuredFeedIsSet
        feedIsSet = set
        controller = SPUStandardUpdaterController(startingUpdater: set, updaterDelegate: delegate, userDriverDelegate: nil)
        if set {
            observation = controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.canCheck = $0 }
        }
    }

    /// Called once from `applicationDidFinishLaunching`; touching `shared` creates (and, when allowed, starts) the updater.
    func start() {}

    private var updater: SPUUpdater? { feedIsSet ? controller.updater : nil }

    func checkForUpdates() { updater?.checkForUpdates() }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }
    var lastCheck: Date? { updater?.lastUpdateCheckDate }
}

/// App-menu item. Disabled, with the reason as its title, in development builds.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = MacUpdater.shared
    var body: some View {
        if updater.feedIsSet {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        } else {
            Button("Updates Are Off in Development Builds") {}
                .disabled(true)
        }
    }
}
