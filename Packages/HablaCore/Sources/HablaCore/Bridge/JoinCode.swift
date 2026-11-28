import Foundation
import CryptoKit
import CommonCrypto

/// A one-time code that lets a new device into an account (Docs/cloud-bridge.md, "Keys").
/// 60 random bits in Crockford base32, shown as `XXXX-XXXX-XXXX`. The Worker only ever sees a
/// PBKDF2/HKDF derivative of it (`id`) and the account key sealed with another (`wrap`).
public struct JoinCode: Sendable, Equatable {
    /// The 12 characters, no dashes.
    public let raw: String

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let rounds: UInt32 = 200_000

    public static func random() -> JoinCode {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return JoinCode(raw: String(bytes.map { alphabet[Int($0) & 31] }))
    }

    /// Reads what someone typed (any case, dashes and spaces ignored, O→0, I/L→1). Nil unless 12 symbols.
    public init?(_ typed: String) {
        var out = ""
        for ch in typed.uppercased() {
            switch ch {
            case "-", " ", "\u{2010}", "\u{2013}": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                guard Self.alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        guard out.count == 12 else { return nil }
        raw = out
    }

    init(raw: String) { self.raw = raw }

    /// `XXXX-XXXX-XXXX`
    public var display: String {
        let c = Array(raw)
        return [0, 4, 8].map { String(c[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// What the iPhone's Camera opens (and what a Mac's QR code shows).
    public func link(bridge: URL?) -> URL {
        var u = URLComponents()
        u.scheme = "habla"; u.host = "join"
        u.queryItems = [URLQueryItem(name: "c", value: raw)] + (bridge.map { [URLQueryItem(name: "u", value: $0.absoluteString)] } ?? [])
        return u.url!
    }

    /// Reads a `habla://join?c=…&u=…` link.
    public static func parse(link: URL) -> (code: JoinCode, bridge: URL?)? {
        guard let comps = URLComponents(url: link, resolvingAgainstBaseURL: false), comps.scheme == "habla", comps.host == "join",
              let c = comps.queryItems?.first(where: { $0.name == "c" })?.value, let code = JoinCode(c) else { return nil }
        let u = comps.queryItems?.first(where: { $0.name == "u" })?.value.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" || $0.host == "127.0.0.1" ? $0 : nil }
        return (code, u)
    }

    // MARK: Keys

    struct Derived { let id: String; let wrap: SymmetricKey }

    func derive() -> Derived {
        let password = Array(raw.utf8)
        let salt = Array("habla-join-v1".utf8)
        var out = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), Self.rounds, &out, out.count)
        let s = SymmetricKey(data: out)
        func hkdf(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: s, info: Data(info.utf8), outputByteCount: 32)
        }
        let id = hkdf("id").withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        return Derived(id: id, wrap: hkdf("wrap"))
    }

    /// What the account hands a new device: its key and name.
    public struct Payload: Codable, Equatable, Sendable {
        public var libraryKey: Data
        public var name: String?
    }

    func seal(_ p: Payload, with d: Derived) throws -> String {
        let box = try AES.GCM.seal(try JSONEncoder().encode(p), using: d.wrap, authenticating: Data("habla-join".utf8))
        guard let combined = box.combined else { throw BridgeError.corrupt }
        return combined.base64EncodedString()
    }

    func open(_ wrapped: String, with d: Derived) throws -> Payload {
        guard let data = Data(base64Encoded: wrapped),
              let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: d.wrap, authenticating: Data("habla-join".utf8)),
              let p = try? JSONDecoder().decode(Payload.self, from: plain), p.libraryKey.count == 32 else { throw BridgeError.corrupt }
        return p
    }
}
