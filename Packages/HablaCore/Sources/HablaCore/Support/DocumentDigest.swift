import Foundation
import CryptoKit

public enum DocumentDigest {
    /// KOReader's `partialMD5` document fingerprint, used by KOReader sync
    /// (and so by CrossPoint on the Xteink) to identify a book file.
    /// Samples 1 KB at offsets 0, 1K, 4K, 16K … 1G, emulating LuaJIT's
    /// `bit.lshift(1024, 2*i)` for i = -1…10 (a shift of -2 wraps to 30 → 0).
    public static func koreaderPartialMD5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var md5 = Insecure.MD5()
        for i in -1...10 {
            let shift = UInt32(bitPattern: Int32(2 * i)) & 31
            let offset = UInt64((UInt64(1024) << UInt64(shift)) & 0xFFFF_FFFF)
            if offset >= fileSize { break }
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 1024), !chunk.isEmpty else { break }
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Prefix(of url: URL, length: Int = 16) throws -> String {
        String(try BookBundle.sha256(of: url).prefix(length))
    }
}
