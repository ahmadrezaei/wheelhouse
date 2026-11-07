import Compression
import Foundation

public enum GzipError: Error, Equatable, Sendable {
    case notGzip
    case truncated
    case unsupportedMethod(UInt8)
    case corrupt
    case checksumMismatch
    case sizeMismatch
    /// The decompressed size passed the cap (zip-bomb guard).
    case tooLarge(limit: Int)
}

/// Gzip reader built on the Compression framework (`COMPRESSION_ZLIB` is raw DEFLATE, so the gzip framing is parsed here).
public enum Gzip {
    /// Decompressed-size cap for a Helm release payload (ARCHITECTURE-MAC §5.1).
    public static let defaultLimit = 64 * 1024 * 1024

    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Decompresses one gzip member. The limit is enforced while streaming, so a bomb is never fully inflated.
    public static func decompress(_ input: Data, limit: Int = defaultLimit) throws -> Data {
        let bytes = [UInt8](input)
        guard bytes.count >= 2, bytes[0] == 0x1f, bytes[1] == 0x8b else { throw GzipError.notGzip }
        guard bytes.count >= 18 else { throw GzipError.truncated }
        guard bytes[2] == 8 else { throw GzipError.unsupportedMethod(bytes[2]) }
        let flags = bytes[3]
        var pos = 10
        func need(_ n: Int) throws { if pos + n > bytes.count { throw GzipError.truncated } }
        if flags & 0x04 != 0 {                       // FEXTRA
            try need(2)
            let len = Int(bytes[pos]) | Int(bytes[pos + 1]) << 8
            pos += 2
            try need(len)
            pos += len
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // FNAME, FCOMMENT: zero-terminated
            while true {
                try need(1)
                pos += 1
                if bytes[pos - 1] == 0 { break }
            }
        }
        if flags & 0x02 != 0 { try need(2); pos += 2 }              // FHCRC
        guard bytes.count - pos >= 8 else { throw GzipError.truncated }
        let bodyEnd = bytes.count - 8
        let expectedCRC = UInt32(bytes[bodyEnd]) | UInt32(bytes[bodyEnd + 1]) << 8 | UInt32(bytes[bodyEnd + 2]) << 16 | UInt32(bytes[bodyEnd + 3]) << 24
        let expectedSize = UInt32(bytes[bodyEnd + 4]) | UInt32(bytes[bodyEnd + 5]) << 8 | UInt32(bytes[bodyEnd + 6]) << 16 | UInt32(bytes[bodyEnd + 7]) << 24

        let out = try inflate(Array(bytes[pos..<bodyEnd]), limit: limit)
        guard crc32(out) == expectedCRC else { throw GzipError.checksumMismatch }
        guard UInt32(truncatingIfNeeded: out.count) == expectedSize else { throw GzipError.sizeMismatch }
        return Data(out)
    }

    /// Raw DEFLATE, streamed into 64 KB chunks.
    static func inflate(_ body: [UInt8], limit: Int) throws -> [UInt8] {
        let chunk = 64 * 1024
        var out: [UInt8] = []
        out.reserveCapacity(min(max(body.count * 4, 1024), limit))
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw GzipError.corrupt
        }
        defer { compression_stream_destroy(streamPtr) }

        // A valid (never dereferenced when the size is 0) source pointer for an empty body.
        let padded = body.isEmpty ? [UInt8(0)] : body
        return try padded.withUnsafeBufferPointer { src -> [UInt8] in
            streamPtr.pointee.src_ptr = UnsafePointer(src.baseAddress!)
            streamPtr.pointee.src_size = body.count
            streamPtr.pointee.dst_ptr = dst
            streamPtr.pointee.dst_size = chunk
            while true {
                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPtr.pointee.dst_size
                if produced > 0 {
                    if out.count + produced > limit { throw GzipError.tooLarge(limit: limit) }
                    out.append(contentsOf: UnsafeBufferPointer(start: dst, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return out
                case COMPRESSION_STATUS_OK:
                    // Output buffer not full and no input left: the DEFLATE stream ended early.
                    if streamPtr.pointee.dst_size != 0 && streamPtr.pointee.src_size == 0 { throw GzipError.truncated }
                    streamPtr.pointee.dst_ptr = dst
                    streamPtr.pointee.dst_size = chunk
                default:
                    throw GzipError.corrupt
                }
            }
        }
    }

    // MARK: CRC-32 (IEEE 802.3, as used by gzip)

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
