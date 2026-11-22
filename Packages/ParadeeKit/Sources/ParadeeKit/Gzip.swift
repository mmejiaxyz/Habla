import Foundation

/// gzip decompression. Apple's `NSData.decompressed(using: .zlib)` inflates raw DEFLATE only, so the
/// gzip envelope is parsed first: the 10-byte header, the optional FEXTRA/FNAME/FCOMMENT/FHCRC fields
/// named by its flags byte, and the 8-byte CRC32+ISIZE trailer are all skipped, leaving the raw stream.
enum GzipError: Error, CustomStringConvertible {
    case tooShort
    case notGzip
    case truncated
    case inflate

    var description: String {
        switch self {
        case .tooShort: return "gzip data is too short"
        case .notGzip: return "data is not gzip"
        case .truncated: return "gzip data is truncated"
        case .inflate: return "gzip data did not inflate"
        }
    }
}

enum Gzip {
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count >= 18 else { throw GzipError.tooShort }
        guard data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else { throw GzipError.notGzip }
        let flags = data[3]
        var i = 10
        func skipNullTerminated() throws {
            while i < data.count, data[i] != 0 { i += 1 }
            guard i < data.count else { throw GzipError.truncated }
            i += 1
        }
        if flags & 0x04 != 0 {   // FEXTRA: 2-byte little-endian length, then that many bytes
            guard i + 2 <= data.count else { throw GzipError.truncated }
            let xlen = Int(data[i]) | Int(data[i + 1]) << 8
            i += 2 + xlen
            guard i <= data.count else { throw GzipError.truncated }
        }
        if flags & 0x08 != 0 { try skipNullTerminated() }   // FNAME
        if flags & 0x10 != 0 { try skipNullTerminated() }   // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }                     // FHCRC
        guard i + 8 <= data.count else { throw GzipError.truncated }
        let deflate = data.subdata(in: i ..< (data.count - 8))
        let out = try (deflate as NSData).decompressed(using: .zlib) as Data?
        guard let out else { throw GzipError.inflate }
        return out
    }
}
