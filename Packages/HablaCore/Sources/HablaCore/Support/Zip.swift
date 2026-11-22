import Foundation
import Compression

public enum ZipError: Error, CustomStringConvertible {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16, String)
    case entryNotFound(String)

    public var description: String {
        switch self {
        case .notAZip: return "Not a ZIP/EPUB file"
        case .corrupt(let s): return "Corrupt archive: \(s)"
        case .unsupportedMethod(let m, let n): return "Unsupported compression method \(m) for \(n)"
        case .entryNotFound(let n): return "Missing entry: \(n)"
        }
    }
}

/// Minimal read-only ZIP reader (stored + deflate), enough for EPUB containers.
/// Uses Apple's Compression framework, so no third-party dependency.
public struct ZipArchive {
    public struct Entry {
        public let path: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    public let entries: [String: Entry]
    private let data: Data

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }

        // End of central directory: search backwards (comment can be up to 64 KB).
        var eocd = -1
        let lowerBound = max(0, data.count - 22 - 65_535)
        var i = data.count - 22
        while i >= lowerBound {
            if data.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let count = Int(data.u16(eocd + 10))
        var p = Int(data.u32(eocd + 16))
        var result: [String: Entry] = [:]
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4b50 else {
                throw ZipError.corrupt("central directory")
            }
            let nameLen = Int(data.u16(p + 28))
            let extraLen = Int(data.u16(p + 30))
            let commentLen = Int(data.u16(p + 32))
            guard p + 46 + nameLen <= data.count else { throw ZipError.corrupt("name") }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            result[name] = Entry(
                path: name,
                method: data.u16(p + 10),
                compressedSize: Int(data.u32(p + 20)),
                uncompressedSize: Int(data.u32(p + 24)),
                localHeaderOffset: Int(data.u32(p + 42))
            )
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = result
    }

    public func contains(_ path: String) -> Bool { entries[path] != nil }

    public func read(_ path: String) throws -> Data {
        guard let e = entries[path] ?? entries.first(where: {
            $0.key.caseInsensitiveCompare(path) == .orderedSame
        })?.value else { throw ZipError.entryNotFound(path) }

        let h = e.localHeaderOffset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4b50 else {
            throw ZipError.corrupt("local header for \(path)")
        }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("data for \(path)") }
        let compressed = data.subdata(in: start..<(start + e.compressedSize))

        switch e.method {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, expectedSize: e.uncompressedSize, name: path)
        default:
            throw ZipError.unsupportedMethod(e.method, path)
        }
    }

    public func readString(_ path: String) throws -> String {
        let d = try read(path)
        return String(data: d, encoding: .utf8)
            ?? String(data: d, encoding: .utf16)
            ?? String(decoding: d, as: UTF8.self)
    }

    /// Raw DEFLATE (RFC 1951) — what Apple calls COMPRESSION_ZLIB.
    static func inflate(_ input: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt("inflate \(name)") }
        return output
    }
}

/// Minimal ZIP writer (stored, no compression). Used for `.habla` exports
/// (audio is already compressed) and for test fixtures.
public struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    public mutating func add(_ path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(body.count)

        var local = Data()
        local.append32(0x0403_4b50); local.append16(20); local.append16(0x0800); local.append16(0)
        local.append16(0); local.append16(0x21)          // time / date (1980-01-01)
        local.append32(crc); local.append32(UInt32(data.count)); local.append32(UInt32(data.count))
        local.append16(UInt16(name.count)); local.append16(0)
        body.append(local); body.append(name); body.append(data)

        var c = Data()
        c.append32(0x0201_4b50); c.append16(20); c.append16(20); c.append16(0x0800); c.append16(0)
        c.append16(0); c.append16(0x21)
        c.append32(crc); c.append32(UInt32(data.count)); c.append32(UInt32(data.count))
        c.append16(UInt16(name.count)); c.append16(0); c.append16(0); c.append16(0); c.append16(0)
        c.append32(0); c.append32(offset)
        central.append(c); central.append(name)
        count += 1
    }

    public func finalize() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append32(0x0605_4b50); out.append16(0); out.append16(0)
        out.append16(count); out.append16(count)
        out.append32(UInt32(central.count)); out.append32(cdOffset); out.append16(0)
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    mutating func append16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func append32(_ v: UInt32) { append16(UInt16(v & 0xFFFF)); append16(UInt16(v >> 16)) }
}
