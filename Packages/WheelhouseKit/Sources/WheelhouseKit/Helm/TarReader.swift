import Foundation

/// One regular file of a tar archive.
public struct TarEntry: Sendable, Hashable {
    public var path: String
    public var data: Data
}

/// A minimal tar reader for chart archives (`.tgz`): regular files only, ustar plus GNU long names and pax `path` records.
public enum TarReader {
    public enum TarError: Error, Equatable, Sendable { case truncated, badHeader }

    /// Reads regular files. `filter` skips entries by path before their data is copied; `maxEntrySize` guards a single entry.
    public static func entries(in tar: Data, maxEntrySize: Int = 16 * 1024 * 1024, filter: (String) -> Bool = { _ in true }) throws -> [TarEntry] {
        let bytes = [UInt8](tar)
        var entries: [TarEntry] = []
        var pos = 0
        var longName: String?
        var paxPath: String?
        while pos + 512 <= bytes.count {
            let header = bytes[pos..<pos + 512]
            if header.allSatisfy({ $0 == 0 }) { break }                    // end-of-archive block
            guard let size = octal(bytes, pos + 124, 12) else { throw TarError.badHeader }
            let type = bytes[pos + 156]
            var name = string(bytes, pos, 100)
            if string(bytes, pos + 257, 5) == "ustar" {
                let prefix = string(bytes, pos + 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            let dataStart = pos + 512
            guard size >= 0, dataStart + size <= bytes.count else { throw TarError.truncated }
            let padded = (size + 511) / 512 * 512
            switch type {
            case UInt8(ascii: "L"):                                           // GNU long name
                longName = String(decoding: bytes[dataStart..<dataStart + size].prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"):                                           // pax extended header: "<len> path=<value>\n"
                let text = String(decoding: bytes[dataStart..<dataStart + size], as: UTF8.self)
                for record in text.split(separator: "\n") {
                    if let eq = record.firstIndex(of: "="), record[..<eq].hasSuffix(" path") {
                        paxPath = String(record[record.index(after: eq)...])
                    }
                }
            case 0, UInt8(ascii: "0"):                                        // regular file
                let path = paxPath ?? longName ?? name
                longName = nil
                paxPath = nil
                if filter(path) {
                    guard size <= maxEntrySize else { throw TarError.badHeader }
                    entries.append(TarEntry(path: path, data: Data(bytes[dataStart..<dataStart + size])))
                }
            default:
                longName = nil
                paxPath = nil
            }
            pos = dataStart + padded
        }
        return entries
    }

    /// Reads a `.tgz`.
    public static func entries(inGzip tgz: Data, limit: Int = 256 * 1024 * 1024, filter: (String) -> Bool = { _ in true }) throws -> [TarEntry] {
        try entries(in: try Gzip.decompress(tgz, limit: limit), filter: filter)
    }

    private static func string(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        String(decoding: bytes[offset..<offset + length].prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func octal(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> Int? {
        let field = bytes[offset..<offset + length]
        if let first = field.first, first & 0x80 != 0 { return nil }          // base-256 sizes (over 8 GB) are not charts
        let text = String(decoding: field.filter { $0 != 0 && $0 != 32 }, as: UTF8.self)
        return text.isEmpty ? 0 : Int(text, radix: 8)
    }
}
