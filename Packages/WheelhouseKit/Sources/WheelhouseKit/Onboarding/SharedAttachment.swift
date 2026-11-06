import Foundation

/// Size cap and UTF-8 decoding for text handed to the Share extension (a file, raw data or a pasted message).
public enum SharedAttachment {
    /// A kubeconfig is a few KB; anything above 1 MB is not one and must not be loaded into the extension's small memory budget.
    public static let maxBytes = 1_048_576

    public enum Failure: Error, Equatable, Sendable {
        case tooLarge
        case empty
        case notUTF8
        case unreadable
    }

    /// Decodes shared bytes as UTF-8 text (BOM tolerated), enforcing the size cap.
    public static func decode(_ data: Data, maxBytes: Int = maxBytes) throws -> String {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard !data.isEmpty else { throw Failure.empty }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.notUTF8 }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty }
        return text
    }

    /// Decodes pasted/shared plain text, enforcing the same cap (measured in UTF-8 bytes).
    public static func decode(text: String, maxBytes: Int = maxBytes) throws -> String {
        try decode(Data(text.utf8), maxBytes: maxBytes)
    }

    /// Reads a file URL, checking its size BEFORE loading it.
    public static func read(fileURL url: URL, maxBytes: Int = maxBytes) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.unreadable }
        return try decode(data, maxBytes: maxBytes)
    }

    /// User-facing explanation.
    public static func message(for failure: Failure) -> String {
        switch failure {
        case .tooLarge: "This is too large to be a kubeconfig (over 1 MB)."
        case .empty: "The shared item is empty."
        case .notUTF8: "The shared item isn’t readable text."
        case .unreadable: "Couldn’t read the shared item."
        }
    }
}
