import Foundation
import CryptoKit
import Security

/// The keys that make the Cloudflare bridge blind (Docs/cloud-bridge.md).
///
/// One random 32-byte **library key** lives on the Mac and on paired phones only. Everything
/// else is derived from it: the AES-GCM key that seals every object, the HMAC key that turns
/// logical names ("state/<device>", "book/<id>/<rev>/<path>#3") into opaque hex, and the bearer
/// token the Worker checks (it stores only the token's SHA-256).
public struct BridgeKeys: Sendable {
    public static let chunkSize = 8 * 1024 * 1024
    static let statePadding = 4096
    static let chunkPadding = 64 * 1024

    let encKey: SymmetricKey
    let nameKey: SymmetricKey
    public let token: String
    /// Wi-Fi: the key a Mac proves it holds (so an iPhone can pin its certificate) and the
    /// token devices of the account send it. Never sent to the bridge.
    let lanKey: SymmetricKey
    public let lanToken: String

    public init(libraryKey: Data) {
        let master = SymmetricKey(data: libraryKey)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("habla-bridge-v1".utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        func base64url(_ k: SymmetricKey) -> String {
            k.withUnsafeBytes { Data($0) }.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        encKey = derive("enc")
        nameKey = derive("name")
        token = base64url(derive("token"))
        lanKey = derive("lan")
        lanToken = base64url(derive("lan-token"))
    }

    /// What a Mac advertises on Wi-Fi (Bonjour TXT `acct`): the same for every device of the
    /// account, meaningless to anyone else.
    public var accountTag: String {
        HMAC<SHA256>.authenticationCode(for: Data("tag".utf8), using: lanKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A Mac's answer to an iPhone's random nonce, bound to the certificate the iPhone sees: a
    /// machine in the middle (other certificate) can't produce it without the account key.
    public func lanProof(fingerprint: String, nonce: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("\(fingerprint.lowercased())|\(nonce)".utf8), using: lanKey)
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func newLibraryKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
        return Data(bytes)
    }

    /// What the Worker stores to recognise this library.
    public var tokenHash: String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The opaque name an object has on the bridge.
    public func objectName(_ logical: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(logical.utf8), using: nameKey)
            .prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    /// `0x01 ‖ nonce ‖ ciphertext ‖ tag`. The plaintext carries its length and is zero-padded,
    /// so sizes say little; the logical name is authenticated, so a blob can't be swapped.
    public func seal(_ plaintext: Data, logical: String, padTo: Int) throws -> Data {
        var body = Data(count: 8)
        body.withUnsafeMutableBytes { $0.storeBytes(of: UInt64(plaintext.count).bigEndian, as: UInt64.self) }
        body.append(plaintext)
        let padded = (body.count + padTo - 1) / padTo * padTo
        body.append(Data(count: padded - body.count))
        let box = try AES.GCM.seal(body, using: encKey, authenticating: Data(logical.utf8))
        guard let combined = box.combined else { throw BridgeError.corrupt }
        return Data([1]) + combined
    }

    public func open(_ blob: Data, logical: String) throws -> Data {
        guard blob.count > 1 + 12 + 16 + 8, blob.first == 1 else { throw BridgeError.corrupt }
        let body: Data
        do { body = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst()), using: encKey, authenticating: Data(logical.utf8)) }
        catch { throw BridgeError.corrupt }
        let length = body.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard length <= UInt64(body.count - 8) else { throw BridgeError.corrupt }
        return Data(body.dropFirst(8).prefix(Int(length)))
    }
}
