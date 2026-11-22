import Foundation

/// Updates published by GitHub Actions: every push to `main` becomes a release tagged
/// `build-N` carrying `Habla-Studio.zip` (Mac), `Habla.ipa` (iPhone) and `altstore.json`.
public struct AppUpdate: Equatable, Sendable {
    public static let repository = "pulpt37/Habla"
    /// AltStore source: always points at the newest release.
    public static let altStoreSource = URL(string: "https://github.com/\(repository)/releases/latest/download/altstore.json")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    public var build: Int
    public var version: String
    public var notes: String
    public var assets: [String: URL]

    public init(build: Int, version: String, notes: String, assets: [String: URL]) {
        self.build = build; self.version = version; self.notes = notes; self.assets = assets
    }

    /// The running app's build number (`CFBundleVersion`); 0 for local/dev builds.
    public static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Parses GitHub's `releases/latest` JSON. Nil for anything that isn't a `build-N` release.
    public static func parse(_ data: Data) -> AppUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL }
            var tag_name: String; var name: String?; var body: String?
            var draft: Bool?; var prerelease: Bool?
            var assets: [Asset]
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data), r.draft != true, r.prerelease != true,
              r.tag_name.hasPrefix("build-"), let build = Int(r.tag_name.dropFirst("build-".count)) else { return nil }
        var assets: [String: URL] = [:]
        for a in r.assets { assets[a.name] = a.browser_download_url }
        return AppUpdate(build: build, version: r.name ?? "Build \(build)", notes: r.body ?? "", assets: assets)
    }

    /// The newest published release, or nil when offline / nothing published.
    public static func latest(session: URLSession = .shared) async -> AppUpdate? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Habla-Updater", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// A newer release than the one running, if any.
    public static func available(installed: Int = installedBuild) async -> AppUpdate? {
        guard let u = await latest(), u.build > installed else { return nil }
        return u
    }
}
