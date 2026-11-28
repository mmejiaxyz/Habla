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
        case .unauthorized: return "The cloud doesn't recognise this account."
        case .http(let code): return "The cloud bridge answered \(code)."
        case .network(let m): return "Can't reach the cloud bridge: \(m)"
        case .corrupt: return "Something from the cloud bridge didn't decrypt."
        }
    }
}

/// Where the account's Worker is and the key that makes it blind. Lives on the Mac
/// (`Security/bridge.json`) and on the iPhone (Keychain); reaches a new device only sealed by a
/// one-time code.
public struct BridgeConfig: Codable, Equatable, Sendable {
    public var url: URL
    public var libraryKey: Data
    public init(url: URL, libraryKey: Data) { self.url = url; self.libraryKey = libraryKey }
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

    // MARK: v2: the account (Docs/cloud-bridge.md)

    /// Creates an account (needs the Worker's server key). Fine if it already exists.
    public func createAccount(tokenHash: String, serverKey: String) async throws {
        var r = request("v2/accounts", method: "POST", auth: false)
        r.setValue(serverKey, forHTTPHeaderField: "X-Habla-Enroll")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["tokenHash": tokenHash])
        _ = try await perform(r)
    }

    /// Leaves a one-time code's sealed payload with the account (15 minutes, works once).
    public func offer(_ code: JoinCode, payload: JoinCode.Payload) async throws {
        let d = code.derive()
        var r = request("v2/codes", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["id": d.id, "wrapped": try code.seal(payload, with: d)])
        _ = try await perform(r)
    }

    /// Redeems a one-time code: the account's key and name. `BridgeError.http(404)`: used, expired or mistyped.
    public static func join(_ code: JoinCode, at baseURL: URL, session: URLSession = .shared) async throws -> JoinCode.Payload {
        let d = code.derive()
        let c = BridgeClient(baseURL: baseURL, token: "", session: session)
        var r = c.request("v2/join", method: "POST", auth: false)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["id": d.id])
        let (data, _) = try await c.perform(r)
        guard let wrapped = (try? JSONDecoder().decode([String: String].self, from: data))?["wrapped"] else { throw BridgeError.corrupt }
        return try code.open(wrapped, with: d)
    }

    /// One round with the account: this device's report in, the account's view and tasks out.
    func sync(_ body: Data) async throws -> Data {
        var r = request("v2/sync", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return try await perform(r).0
    }

    func removeDevice(_ id: String) async throws {
        var r = request("v2/devices/remove", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["id": id])
        _ = try await perform(r)
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
