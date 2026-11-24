import Foundation

public enum BridgeError: Error, Equatable, CustomStringConvertible {
    /// A free-tier budget is used up (`storage`, `classA`, `classB`, `requests`): wait for the next period.
    case capReached(String)
    case unauthorized
    case http(Int)
    case network(String)
    /// An object didn't decrypt or didn't match its checksum.
    case corrupt

    public var description: String {
        switch self {
        case .capReached(let c): return "The cloud bridge reached its free limit (\(c)); syncing at home only for now."
        case .unauthorized: return "The cloud bridge doesn't recognise this library."
        case .http(let code): return "The cloud bridge answered \(code)."
        case .network(let m): return "Can't reach the cloud bridge: \(m)"
        case .corrupt: return "Something from the cloud bridge didn't decrypt."
        }
    }
}

/// Where the bridge is and the key that makes it blind. Lives on the Mac (`Security/bridge.json`)
/// and on paired phones (Keychain); never leaves them except over the pinned LAN link.
public struct BridgeConfig: Codable, Equatable, Sendable {
    public var url: URL
    public var libraryKey: Data
    public init(url: URL, libraryKey: Data) { self.url = url; self.libraryKey = libraryKey }
}

/// An account: one library on every device. Its QR code (and the same text to paste on a Mac)
/// is a `habla://account` link holding the bridge URL, the library key and the name. Whoever
/// has it is one of your devices: it works like a password.
public enum AccountCode {
    public static func url(_ c: BridgeConfig, name: String?) -> URL {
        var u = URLComponents()
        u.scheme = "habla"; u.host = "account"
        let key = c.libraryKey.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        u.queryItems = [URLQueryItem(name: "u", value: c.url.absoluteString), URLQueryItem(name: "k", value: key)]
            + ((name?.isEmpty == false) ? [URLQueryItem(name: "n", value: name)] : [])
        return u.url!
    }

    /// Reads an account link, or an older `habla-link:` code.
    public static func parse(_ text: String) -> (config: BridgeConfig, name: String?)? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let c = BridgeCode.parseLink(raw) { return (c, nil) }
        guard let comps = URLComponents(string: raw), comps.scheme == "habla", comps.host == "account",
              let items = comps.queryItems else { return nil }
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let u = v("u").flatMap(URL.init(string:)), u.scheme == "https", var k = v("k") else { return nil }
        k = k.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while k.count % 4 != 0 { k += "=" }
        guard let key = Data(base64Encoded: k), key.count == 32 else { return nil }
        return (BridgeConfig(url: u, libraryKey: key), v("n").map { String($0.prefix(60)) })
    }
}

/// The codes people paste between Macs. A link code joins a library (it holds the key: a
/// password). An invite code lets someone else's Mac start its own library on the same bridge.
public enum BridgeCode {
    public struct Invite: Codable, Equatable, Sendable {
        public var url: URL; public var invite: String
        public init(url: URL, invite: String) { self.url = url; self.invite = invite }
    }

    public static func link(_ c: BridgeConfig) -> String? {
        (try? JSONEncoder().encode(c)).map { "habla-link:" + $0.base64EncodedString() }
    }
    public static func parseLink(_ code: String) -> BridgeConfig? {
        guard let c: BridgeConfig = decode(code, prefix: "habla-link:"), c.libraryKey.count == 32, c.url.scheme == "https" else { return nil }
        return c
    }
    public static func invite(_ i: Invite) -> String? {
        (try? JSONEncoder().encode(i)).map { "habla-invite:" + $0.base64EncodedString() }
    }
    public static func parseInvite(_ code: String) -> Invite? {
        guard let i: Invite = decode(code, prefix: "habla-invite:"), i.url.scheme == "https", !i.invite.isEmpty else { return nil }
        return i
    }
    static func decode<T: Decodable>(_ code: String, prefix: String) -> T? {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix(prefix), let d = Data(base64Encoded: String(raw.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

/// One object as the Worker lists it.
public struct BridgeObject: Codable, Equatable, Sendable {
    public var name: String
    public var size: Int
    public var etag: String?
    public var updated: String?
    /// State documents: when that device last checked in, and whether it is listening right now.
    public var seen: String?
    public var online: Bool?
}

public struct BridgeUsage: Codable, Equatable, Sendable {
    public var storageBytes: Int, portfolioBytes: Int, storageCapBytes: Int
    public var classA: Int, classACap: Int, classB: Int, classBCap: Int
    public var requestsToday: Int, requestsCapDay: Int
    /// Room left for new uploads, after everything else on the account.
    public var freeBytes: Int { max(0, storageCapBytes - storageBytes - portfolioBytes) }
}

/// The Worker API (Docs/cloud-bridge.md). Moves only sealed bytes under opaque names.
public struct BridgeClient: Sendable {
    public enum Kind: String, Sendable { case state, transit }
    public let baseURL: URL
    let token: String
    /// This device's document name: listing the documents is its check-in.
    let device: String?
    let session: URLSession

    public init(baseURL: URL, token: String, device: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.device = device; self.session = session
    }

    /// Registers this library's token hash (Mac, once). Needs the Worker's enrollment secret.
    public func enroll(tokenHash: String, secret: String) async throws {
        var r = request("v1/spaces", method: "POST", auth: false)
        r.setValue(secret, forHTTPHeaderField: "X-Habla-Enroll")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["tokenHash": tokenHash])
        _ = try await perform(r)
    }

    /// Registers someone else's library with a one-time invite from an enrolled one.
    public func enroll(tokenHash: String, invite: String) async throws {
        var r = request("v1/spaces", method: "POST", auth: false)
        r.setValue(invite, forHTTPHeaderField: "X-Habla-Invite")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["tokenHash": tokenHash])
        _ = try await perform(r)
    }

    /// A one-time invite (7 days) that lets someone else's Mac start its own library here.
    public func createInvite() async throws -> String {
        let (data, _) = try await perform(request("v1/invites", method: "POST"))
        guard let invite = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["invite"] as? String else {
            throw BridgeError.http(500)
        }
        return invite
    }

    public func usage() async throws -> BridgeUsage {
        let (data, _) = try await perform(request("v1/usage"))
        return try JSONDecoder().decode(BridgeUsage.self, from: data)
    }

    public func list(_ kind: Kind) async throws -> [BridgeObject] {
        let (data, _) = try await perform(request("v1/\(kind.rawValue)"))
        return try JSONDecoder().decode([BridgeObject].self, from: data)
    }

    /// The object's bytes, or nil when `etag` still matches (nothing new to read).
    public func get(_ kind: Kind, _ name: String, etag: String? = nil) async throws -> (data: Data?, etag: String?) {
        var r = request("v1/\(kind.rawValue)/\(name)")
        if let etag { r.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await perform(r, allow304: true)
        let tag = http.value(forHTTPHeaderField: "ETag")?.replacingOccurrences(of: "\"", with: "")
        return (http.statusCode == 304 ? nil : data, tag)
    }

    @discardableResult
    public func put(_ kind: Kind, _ name: String, _ data: Data) async throws -> String? {
        var r = request("v1/\(kind.rawValue)/\(name)", method: "PUT")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 300
        let (body, _) = try await perform(r, upload: data)
        return (try? JSONDecoder().decode([String: String].self, from: body))?["etag"]
    }

    public func delete(_ kind: Kind, _ name: String) async throws {
        _ = try await perform(request("v1/\(kind.rawValue)/\(name)", method: "DELETE"), allow404: true)
    }

    // MARK: HTTP

    func request(_ path: String, method: String = "GET", auth: Bool = true) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 60
        if auth { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let device { r.setValue(device, forHTTPHeaderField: "X-Habla-Device") }
        return r
    }

    func perform(_ r: URLRequest, upload: Data? = nil, allow304: Bool = false, allow404: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            if let upload { (data, response) = try await session.upload(for: r, from: upload) }
            else { (data, response) = try await session.data(for: r) }
        } catch { throw BridgeError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw BridgeError.network("no response") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 304 where allow304: return (data, http)
        case 404 where allow404: return (data, http)
        case 401, 403: throw BridgeError.unauthorized
        case 429, 507:
            let cap = (try? JSONDecoder().decode([String: String].self, from: data))?["cap"] ?? (http.statusCode == 507 ? "storage" : "requests")
            throw BridgeError.capReached(cap)
        default: throw BridgeError.http(http.statusCode)
        }
    }
}
