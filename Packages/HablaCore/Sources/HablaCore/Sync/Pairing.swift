import Foundation
import CryptoKit
import Security

/// Pairing an iPhone with one Mac, so several Macs on the same Wi-Fi stay apart and nobody
/// else on the network can read your library, positions, or send you books.
///
/// - The Mac has a random **library ID** (advertised in Bonjour, never personal data) and a
///   self-signed **TLS certificate**. All iPhone traffic is HTTPS pinned to that certificate.
/// - To pair, the Mac shows a one-time **code** (10 characters, valid 10 minutes) and a QR code
///   carrying the code plus the certificate fingerprint. The iPhone proves it knows the code
///   with `HMAC(code, fingerprint it sees ‖ device id)`: a machine in the middle shows a different
///   certificate, so its proof can't be replayed to the Mac, and the code never crosses the network.
/// - The Mac answers with a random per-device **token** (stored hashed). Every request carries it;
///   devices can be forgotten from the Mac at any time.
public enum Pairing {
    /// Crockford base32 without look-alikes (no I, L, O, U): ~50 bits per code.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return String(chars[0..<5]) + "-" + String(chars[5..<10])
    }

    /// Accepts what people type: lowercase, spaces, missing dash, O for 0, I/L for 1.
    public static func normalize(_ code: String) -> String {
        let mapped = code.uppercased().compactMap { c -> Character? in
            switch c {
            case "O": return "0"
            case "I", "L": return "1"
            default: return alphabet.contains(c) ? c : nil
            }
        }
        return String(mapped)
    }

    public static func proof(code: String, fingerprint: String, deviceID: String) -> String {
        let key = SymmetricKey(data: Data(normalize(code).utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(fingerprint.lowercased())|\(deviceID)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a certificate's DER bytes, hex.
    public static func fingerprint(_ cert: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the QR code on the Mac carries (opened by the iPhone camera as a `habla://pair` link).
public struct PairingInvite: Equatable, Sendable {
    public var libraryID: String
    public var name: String
    public var address: String?       // "192.168.1.20:8787" (hint; Bonjour finds it anyway)
    public var fingerprint: String
    public var code: String

    public init(libraryID: String, name: String, address: String?, fingerprint: String, code: String) {
        self.libraryID = libraryID; self.name = name; self.address = address; self.fingerprint = fingerprint; self.code = code
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "habla"; c.host = "pair"
        c.queryItems = [URLQueryItem(name: "id", value: libraryID), URLQueryItem(name: "n", value: name),
                        URLQueryItem(name: "f", value: fingerprint), URLQueryItem(name: "c", value: code)]
            + (address.map { [URLQueryItem(name: "a", value: $0)] } ?? [])
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "habla", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let id = v("id"), let f = v("f"), let c = v("c"), f.count == 64 else { return nil }
        self.init(libraryID: id, name: v("n") ?? "Mac", address: v("a"), fingerprint: f, code: c)
    }
}

public struct ServerHello: Codable, Sendable {
    public var name: String
    public var version: String
    public var libraryID: String?
    /// True when this server requires pairing (Habla Studio). `habla serve` is open.
    public var pairing: Bool?
    public var inbox: String?
    /// HMAC of (certificate fingerprint ‖ the caller's nonce) under the account's Wi-Fi key.
    public var accountProof: String?
}

/// A value shared across threads.
public final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    public init(_ value: T) { _value = value }
    public var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

public struct PairRequest: Codable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var proof: String
}

public struct PairResponse: Codable, Sendable {
    public var token: String
    public var libraryID: String
    public var name: String
}

public struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date?
}

/// The Mac's list of paired devices (`devices.json`, tokens stored only as hashes).
public final class DeviceRegistry: @unchecked Sendable {
    public let fileURL: URL
    private var devices: [PairedDevice]
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        devices = (try? JSON.decoder.decode([PairedDevice].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public var all: [PairedDevice] { lock.withLock { devices } }

    /// Pairs (or re-pairs) a device; returns its new token.
    public func register(id: String, name: String) -> String {
        let token = Pairing.randomToken()
        lock.withLock {
            devices.removeAll { $0.id == id }
            devices.append(PairedDevice(id: id, name: String(name.prefix(60)), tokenHash: Pairing.hash(token), pairedAt: Date(), lastSeen: Date()))
        }
        save()
        return token
    }

    /// The device a token belongs to (and marks it seen).
    public func device(forToken token: String?) -> PairedDevice? {
        guard let token, !token.isEmpty else { return nil }
        let h = Pairing.hash(token)
        var found: PairedDevice?
        var dirty = false
        lock.withLock {
            guard let i = devices.firstIndex(where: { $0.tokenHash == h }) else { return }
            if Date().timeIntervalSince(devices[i].lastSeen ?? .distantPast) > 60 { devices[i].lastSeen = Date(); dirty = true }
            found = devices[i]
        }
        if dirty { save() }
        return found
    }

    public func forget(_ id: String) {
        lock.withLock { devices.removeAll { $0.id == id } }
        save()
    }

    private func save() {
        let data = lock.withLock { try? JSON.encoder.encode(devices) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// The code currently shown on the Mac. Expires after 10 minutes and after 5 wrong tries,
/// so it can't be guessed online.
public final class PairingWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var code: String?
    private var expires = Date.distantPast
    private var failures = 0
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    /// A fresh code, valid for `lifetime`.
    @discardableResult
    public func open(lifetime: TimeInterval = 600) -> String {
        let c = Pairing.newCode()
        lock.withLock { code = c; expires = Date().addingTimeInterval(lifetime); failures = 0 }
        onChange?()
        return c
    }

    public func close() { lock.withLock { code = nil }; onChange?() }

    public var current: (code: String, expires: Date)? {
        lock.withLock { guard let code, expires > Date() else { return nil }; return (code, expires) }
    }

    /// Checks a proof; a success closes the window (one code pairs one device).
    func verify(proof: String, fingerprint: String, deviceID: String) -> Bool {
        var ok = false, changed = false
        lock.withLock {
            guard let c = code, expires > Date() else { return }
            let expected = Pairing.proof(code: c, fingerprint: fingerprint, deviceID: deviceID)
            if constantTimeEqual(expected, proof.lowercased()) {
                ok = true; code = nil; changed = true
            } else {
                failures += 1
                if failures >= 5 { code = nil; changed = true }
            }
        }
        if changed { onChange?() }
        return ok
    }

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// URLSession trust handling for a Mac's self-signed certificate: accepts exactly the pinned
/// fingerprint; with no pin (first contact while pairing by typed code) it accepts and records
/// what it saw — the pairing proof then binds the code to that certificate.
public final class PinnedTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let pinned: String?
    private let lock = NSLock()
    private var _seen: String?
    public var seen: String? { lock.withLock { _seen } }

    public init(fingerprint: String?) { pinned = fingerprint?.lowercased() }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return completionHandler(.performDefaultHandling, nil)
        }
        let fp = Pairing.fingerprint(leaf)
        lock.withLock { _seen = fp }
        if pinned == nil || pinned == fp { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    /// A session that trusts only this pin.
    public func session(timeout: TimeInterval = 15) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }
}

#if os(macOS)
/// The Mac's TLS identity: a self-signed RSA certificate made once with the system `openssl`
/// and loaded in memory only (never added to the keychain, so updates never trigger prompts).
@available(macOS 15.0, *)
public enum TLSIdentity {
    public static func loadOrCreate(in dir: URL) throws -> (identity: SecIdentity, fingerprint: String) {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let p12 = dir.appendingPathComponent("identity.p12")
        let passFile = dir.appendingPathComponent("identity.pass")
        if !fm.fileExists(atPath: p12.path) || !fm.fileExists(atPath: passFile.path) {
            let pass = Pairing.randomToken()
            let key = dir.appendingPathComponent("key.pem"), cert = dir.appendingPathComponent("cert.pem")
            defer { try? fm.removeItem(at: key); try? fm.removeItem(at: cert) }
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path,
                         "-days", "7300", "-subj", "/CN=Habla Studio"])
            try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:\(pass)"])
            try Data(pass.utf8).write(to: passFile, options: .atomic)
            for f in [p12, passFile] { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
        }
        let pass = String(decoding: try Data(contentsOf: passFile), as: UTF8.self)
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: pass, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let any = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "Habla", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Couldn't load the encryption certificate."])
        }
        let identity = any as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw NSError(domain: "Habla", code: -1) }
        return (identity, Pairing.fingerprint(cert))
    }

    static func openssl(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Habla", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "openssl failed"])
        }
    }
}
#endif
