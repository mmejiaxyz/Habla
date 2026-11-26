import Foundation
import CryptoKit

/// E-reader protocols served by the Mac (Habla Studio), for KOReader and the
/// Xteink running CrossPoint:
///
/// - **KOReader sync** (KOSync): point the device's sync server at `http://<mac>:8787`.
///     POST /users/create · GET /users/auth · PUT /syncs/progress · GET /syncs/progress/{document}
///   Documents match by partial MD5 (Binary mode) or file-name MD5 (CrossPoint's default).
///   Positions translate to/from (chapter, sentence) through `KOReaderPositionMap`.
///
/// - **OPDS catalog** (`/opds/<key>`): the device downloads the original EPUBs. CrossPoint names
///   OPDS downloads itself ("Author - Title.epub"), so those copies match by Binary digest or
///   by the title/filename metadata the device sends — Habla configures Binary matching.
extension HTTPResponse {
    static func object(_ dict: [String: Any], status: Int = 200) -> HTTPResponse {
        var r = rawJSON((try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8))
        r.status = status
        return r
    }
}

extension LibraryServer {

    // MARK: KOReader sync

    func koreaderRoute(_ r: HTTPRequest, _ parts: [String]) -> HTTPResponse {
        if parts == ["users", "create"], r.method == "POST" {
            // Single-user server: any account name is accepted; the password is the configured key.
            let name = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["username"] as? String
            return .json(["username": name ?? "habla"], status: 201)
        }
        guard koreaderAuthorized(r) else { return .json(["message": "Unauthorized"], status: 401) }

        switch (r.method, parts.count) {
        case ("GET", 2) where parts == ["users", "auth"]:
            return .json(["authorized": "OK"])

        case ("PUT", 2) where parts == ["syncs", "progress"]:
            guard let body = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
                  let document = body["document"] as? String,
                  let pointer = body["progress"] as? String else {
                return .json(["message": "Invalid request"], status: 400)
            }
            let device = body["device"] as? String ?? "KOReader"
            // Fingerprint unknown (e.g. "Optimize EPUB" rewrote the file on the device):
            // fall back to the title/author the device sends with koSendMetadata.
            // CrossPoint sends {metadata: {filename, title, authors}} when koSendMetadata is on.
            let meta = body["metadata"] as? [String: Any]
            let match = book(forDocument: document)
                ?? (meta?["filename"] as? String).flatMap { book(forDocument: KOReaderDigest.filename($0)) }
                ?? book(title: (meta?["title"] ?? body["title"]) as? String,
                        author: (meta?["authors"] ?? body["author"]) as? String)
            if let (bundle, _) = match,
               let map = try? KOReaderPositionMap(bundle: bundle),
               let pos = map.position(for: pointer) {
                let fraction = (body["percentage"] as? Double) ?? map.percentage(chapter: pos.chapter, sentence: pos.sentence)
                progress.merge(ReadingPosition(bookID: try! bundle.manifest().id, chapter: pos.chapter, sentence: pos.sentence,
                                               mode: .reading, deviceID: "koreader:\(device)", fraction: fraction))
            }
            // Unknown documents are acknowledged (the device's sync queue must not stall).
            return .object(["document": document, "timestamp": Int(Date().timeIntervalSince1970)])

        case ("GET", 3) where parts[0] == "syncs" && parts[1] == "progress":
            let document = parts[2]
            guard let (bundle, m) = book(forDocument: document),
                  let pos = progress.position(for: m.id),
                  let map = try? KOReaderPositionMap(bundle: bundle),
                  let pointer = map.xpointer(chapter: pos.chapter, sentence: pos.sentence) else {
                // "No progress yet": CrossPoint's client treats 204 as NOT_FOUND and uploads its own.
                return HTTPResponse(status: 204, contentType: "application/json", body: .data(Data()))
            }
            let payload: [String: Any] = [
                "document": document, "progress": pointer,
                "percentage": map.percentage(chapter: pos.chapter, sentence: pos.sentence),
                "device": pos.deviceID.hasPrefix("koreader:") ? String(pos.deviceID.dropFirst(9)) : "Habla",
                "device_id": pos.deviceID, "timestamp": Int(pos.updatedAt.timeIntervalSince1970),
            ]
            return .object(payload)

        default:
            return .json(["message": "Not found"], status: 404)
        }
    }

    /// KOSync sends `x-auth-user` and `x-auth-key` (MD5 of the password). Closed until this Mac
    /// has set up an e-reader (that is what makes the password).
    func koreaderAuthorized(_ r: HTTPRequest) -> Bool {
        guard let key = koreaderKeyMD5, let sent = r.headers["x-auth-key"] else { return false }
        return Self.constantTimeEqual(sent.lowercased(), key.lowercased())
    }

    /// The secret part of the catalog's address. E-readers can't scan the account QR code, so
    /// the Mac (already in the account) writes this address onto the device when it sets it up.
    public static func opdsKey(password: String) -> String {
        SHA256.hash(data: Data("habla-opds|\(password)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    func book(forDocument document: String) -> (BookBundle, BookManifest)? {
        let doc = document.lowercased()
        guard let m = manifests().first(where: { $0.koreaderDigest == doc || $0.koreaderFilenameDigest == doc }) else { return nil }
        return (BookBundle(url: BookBundle.url(for: m.id, in: library)), m)
    }

    func book(title: String?, author: String?) -> (BookBundle, BookManifest)? {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let candidates = manifests().filter { fold($0.title) == fold(title) }
        let pick = candidates.count == 1 ? candidates.first
            : candidates.first { m in author.map { fold(m.author).contains(fold($0.components(separatedBy: ",")[0])) } ?? false }
        return pick.map { (BookBundle(url: BookBundle.url(for: $0.id, in: library)), $0) }
    }

    // MARK: OPDS

    func opdsRoute(_ r: HTTPRequest, _ parts: [String]) -> HTTPResponse {
        // `/opds/<key>` and `/opds/<key>/books/<id>.epub`: without this Mac's key, nothing is there.
        guard let key = opdsKey, parts.count >= 2, Self.constantTimeEqual(parts[1], key) else { return .text(404, "Not found") }
        let parts = Array(parts.dropFirst(2))
        if parts.isEmpty { return opdsFeed(key: key) }
        if parts.count == 2, parts[0] == "books", parts[1].hasSuffix(".epub") {
            let id = String(parts[1].dropLast(5))
            guard let m = manifest(id) else { return .text(404, "No such book") }
            let original = BookImporter.originalURL(for: id, in: library)
            guard FileManager.default.fileExists(atPath: original.path) else { return .text(404, "Original EPUB not kept") }
            var res = HTTPResponse.file(original)
            res.contentType = "application/epub+zip"
            res.headers["Content-Disposition"] = "attachment; filename=\"\(BookImporter.deviceFileName(title: m.title, id: m.id))\""
            return res
        }
        return .text(404, "Not found")
    }


    func opdsFeed(key: String) -> HTTPResponse {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let iso = ISO8601DateFormatter()
        let entries = manifests()
            .filter { FileManager.default.fileExists(atPath: BookImporter.originalURL(for: $0.id, in: library).path) }
            .map { m in """
              <entry>
                <title>\(esc(m.title))</title>
                <id>urn:habla:\(m.id)</id>
                <updated>\(iso.string(from: m.updatedAt))</updated>
                <author><name>\(esc(m.author))</name></author>
                <dc:language>\(esc(m.language))</dc:language>
                <link rel="http://opds-spec.org/acquisition" href="/opds/\(key)/books/\(m.id).epub" type="application/epub+zip"/>
              </entry>
            """ }
            .joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>urn:habla:library</id>
          <title>\(esc(serviceName))</title>
          <updated>\(iso.string(from: Date()))</updated>
          <link rel="self" href="/opds/\(key)" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
          <link rel="start" href="/opds/\(key)" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
        \(entries)
        </feed>
        """
        return HTTPResponse(status: 200, contentType: "application/atom+xml;profile=opds-catalog;kind=acquisition",
                            body: .data(Data(xml.utf8)))
    }
}
