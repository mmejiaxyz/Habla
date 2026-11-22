import Foundation
import HablaCore

// `habla` — drive HablaCore from the terminal (the future Mac app does the same calls).
//
//   habla import <book.epub>                      process an EPUB into a bundle
//   habla list                                    list processed books
//   habla inspect <id> [chapter]                  show chapters / sentences / spoken text
//   habla voices                                  list Kokoro voices
//   habla render <id> [--voice af_heart] [--speed 1.0] [--chapters 3,4] [--engine kokoro|tone]
//   habla serve [--port 8787] [--token SECRET]    share the library with the iPhone
//   habla pull <http://mac:8787> <id> <dir>       download a book like the iPhone does
//   habla export <id> <file.habla>                single-file bundle for AirDrop
//   habla xteink find|setup|send [--host IP]      Xteink (CrossPoint, File Transfer mode open)
//
// Options: --library DIR (default ~/Library/Application Support/Habla Studio/Library)
//          --kokoro DIR  (default: Tools/kokoro found from the current directory)

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Habla Studio", isDirectory: true)

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let customLibrary = option("library").map { URL(fileURLWithPath: $0) }
let library = customLibrary ?? support.appendingPathComponent("Library")
/// With --library, everything (progress, sentence cache) stays inside that folder — never the app's data.
let dataDir = customLibrary ?? support
let progressFile = customLibrary.map { $0.appendingPathComponent(".progress.json") } ?? support.appendingPathComponent("progress.json")
let cacheDir = customLibrary.map { $0.appendingPathComponent(".cache") } ?? support.appendingPathComponent("SentenceCache")
let kokoroDir: URL = option("kokoro").map { URL(fileURLWithPath: $0) } ?? {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("Tools/kokoro")
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("kokoro_worker.py").path) { return candidate }
        dir.deleteLastPathComponent()
    }
    return support.appendingPathComponent("kokoro")
}()
try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

func bundle(_ id: String) -> BookBundle {
    let matches = ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? [])
        .filter { $0.hasPrefix(id) && $0.hasSuffix(".habla") }
    guard matches.count == 1 else { fail(matches.isEmpty ? "no book with id \(id)" : "ambiguous id \(id)") }
    return BookBundle(url: library.appendingPathComponent(matches[0]))
}

func duration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%dh%02dm", s / 3600, (s % 3600) / 60) : String(format: "%dm%02ds", s / 60, s % 60)
}

func printManifest(_ m: BookManifest) {
    print("\(m.title) — \(m.author)  [\(m.id)]  accent \(m.accentColor)  rev \(m.revision)")
    for c in m.chapters {
        let status = c.audioStatus == .ready ? duration(c.duration ?? 0) : c.audioStatus.rawValue
        print(String(format: "  %3d  %@%@  · %d sentences · %d words · %@", c.index,
                     c.isFrontMatter ? "(front) " : "", c.title, c.sentenceCount, c.wordCount, status))
    }
}

let command = args.first ?? "help"
args = Array(args.dropFirst())

do {
    switch command {
    case "import":
        guard let path = args.first else { fail("usage: habla import <book.epub>") }
        let start = Date()
        let b = try BookImporter().importEPUB(at: URL(fileURLWithPath: path), into: library)
        printManifest(try b.manifest())
        print(String(format: "Processed in %.2fs → %@", Date().timeIntervalSince(start), b.url.path))

    case "list":
        for m in LibraryServer(library: library, progress: ProgressStore(fileURL: progressFile)).manifests() {
            let ready = m.chapters.filter { $0.audioStatus == .ready }.count
            print("\(m.id)  \(m.title) — \(m.author)  (\(ready)/\(m.chapters.count) chapters narrated, \(duration(m.totalDuration)))")
        }

    case "inspect":
        guard let id = args.first else { fail("usage: habla inspect <id> [chapter]") }
        let b = bundle(id)
        let m = try b.manifest()
        if args.count > 1, let idx = Int(args[1]), let info = m.chapters.first(where: { $0.index == idx }) {
            let text = try b.chapterText(info)
            print("# \(text.title)\n")
            for block in text.blocks {
                if block.kind == .sceneBreak { print("   ⁂\n"); continue }
                print("[\(block.kind.rawValue)\(block.level.map { " h\($0)" } ?? "")] \(block.source.xpointer)")
                for s in block.sentences {
                    print("  \(s.id): \(block.substring(s.range))")
                    if let spoken = s.spoken { print("      ↳ says: \(spoken)") }
                }
            }
        } else {
            printManifest(m)
        }

    case "voices":
        let engine = KokoroEngine(configuration: .init(toolsDirectory: kokoroDir))
        print(try await engine.voices().joined(separator: "  "))
        await engine.shutdown()

    case "render":
        guard args.first != nil else { fail("usage: habla render <id> [--voice v] [--speed s] [--chapters 1,2]") }
        let voiceID = option("voice") ?? "af_heart"
        let speed = Double(option("speed") ?? "1.0") ?? 1.0
        let only = option("chapters").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let engineName = option("engine") ?? "kokoro"
        let engine: TTSEngine = engineName == "tone" ? ToneEngine() : KokoroEngine(configuration: .init(toolsDirectory: kokoroDir))
        let pipeline = RenderPipeline(engine: engine, cacheDirectory: cacheDir)
        let b = bundle(args[0])
        let start = Date()
        try await pipeline.render(b, voice: VoiceInfo(engine: engine.name, voiceID: voiceID, speed: speed), only: only) { p in
            let line = String(format: "\r  [%d/%d] %@  sentence %d/%d %@", p.chaptersDone + 1, p.chaptersTotal,
                              String(p.chapterTitle.prefix(40)), p.sentence, p.sentenceCount, p.cacheHit ? "(cached)" : "        ")
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        await engine.shutdown()
        print()
        let m = try b.manifest()
        let elapsed = Date().timeIntervalSince(start)
        let rendered = m.chapters.filter { only?.contains($0.index) ?? true }.compactMap(\.duration).reduce(0, +)
        print(String(format: "Done in %@ — %@ of audio (%.1f× real time)", duration(elapsed), duration(rendered),
                     elapsed > 0 ? rendered / elapsed : 0))

    case "serve":
        let port = UInt16(option("port") ?? "") ?? SyncProtocol.defaultPort
        let server = LibraryServer(library: library, progress: ProgressStore(fileURL: progressFile),
                                   serviceName: "Habla on \(Host.current().localizedName ?? "Mac")", accessToken: option("token"))
        server.onEvent = { print("  \($0)") }
        // Xteink sync password (created by `habla xteink setup`); KOSync sends its MD5.
        if let d = try? Data(contentsOf: dataDir.appendingPathComponent(customLibrary == nil ? "xteink.json" : ".xteink.json")),
           let c = try? JSONDecoder().decode([String: String].self, from: d), let pw = c["password"] {
            server.koreaderKeyMD5 = KOReaderDigest.filename(pw)
        }
        let bound = try await server.start(port: port)
        print("Serving \(library.path) on port \(bound) (Bonjour \(SyncProtocol.bonjourType)). Ctrl-C to stop.")
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }

    case "pull":
        guard args.count >= 3, let url = URL(string: args[0]) else { fail("usage: habla pull <url> <id> <dir>") }
        let dest = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let verify = args.contains("--verify")
        let s = try await SyncClient(baseURL: url, accessToken: option("token")).syncBook(args[1], into: dest, verify: verify)
        print("Downloaded \(s.filesDownloaded) files (\(s.bytesDownloaded / 1024) KB), removed \(s.filesRemoved)\(s.upToDate ? " — already up to date" : "")")

    case "xpcheck":   // KOReader position round trip for every sentence of a book
        guard let id = args.first else { fail("usage: habla xpcheck <id>") }
        let b = bundle(id)
        let map = try KOReaderPositionMap(bundle: b)
        var ok = 0, bad = 0
        for ch in try b.manifest().chapters {
            for s in 0..<ch.sentenceCount {
                if let xp = map.xpointer(chapter: ch.index, sentence: s), let p = map.position(for: xp),
                   p.chapter == ch.index, p.sentence == s { ok += 1 }
                else { bad += 1; if bad <= 3 { print("  ✗ ch\(ch.index) s\(s) \(map.xpointer(chapter: ch.index, sentence: s) ?? "nil")") } }
            }
        }
        print("\(try b.manifest().title.prefix(40)): \(ok) ok, \(bad) mismatched")

    case "xteink":   // xteink find | setup | send   (device in File Transfer mode)
        let sub = args.first ?? "find"
        let host = option("host")
        let creds = dataDir.appendingPathComponent(customLibrary == nil ? "xteink.json" : ".xteink.json")
        func credentials() throws -> [String: String] {
            if let d = try? Data(contentsOf: creds), let c = try? JSONDecoder().decode([String: String].self, from: d) { return c }
            let c = ["username": "habla", "password": UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()]
            try JSONEncoder().encode(c).write(to: creds)
            return c
        }
        var devices = host.map { [CrossPointDevice(name: "Xteink", host: $0)] } ?? []
        if devices.isEmpty { devices = await CrossPointDevice.discover() }
        guard let device = devices.first else {
            fail("No Xteink found. On the device open File Transfer (same Wi-Fi), or pass --host <ip shown on screen>")
        }
        let status = try await device.status()
        print("Found \(status.device ?? "CrossPoint") at \(device.host) · firmware \(status.version)")
        let sync = XteinkSync(device: device)
        if sub == "setup" || sub == "send" {
            guard let ip = LocalNetwork.primaryIPv4() else { fail("Can't determine this Mac's Wi-Fi address") }
            let c = try credentials()
            try await sync.configure(macBaseURL: URL(string: "http://\(ip):\(SyncProtocol.defaultPort)")!,
                                     username: c["username"]!, password: c["password"]!)
            print("Sync set up: progress goes to this Mac (\(ip)) whenever the Xteink sleeps; catalog 'Habla (Mac)' added.")
        }
        if sub == "send" {
            let r = try await sync.pushBooks(from: library) { print("  sending \($0)…") }
            print("Sent \(r.sent.count) book(s); \(r.alreadyThere.count) already on the device (in /Habla).")
        }

    case "export":
        guard args.count >= 2 else { fail("usage: habla export <id> <file.habla>") }
        try bundle(args[0]).exportArchive().write(to: URL(fileURLWithPath: args[1]))
        print("Wrote \(args[1])")

    default:
        print("""
        habla — HablaCore command line
          import <book.epub> | list | inspect <id> [chapter] | voices
          render <id> [--voice af_heart] [--speed 1.0] [--chapters 3,4] [--engine kokoro|tone]
          serve [--port 8787] [--token T] | pull <url> <id> <dir> | export <id> <file.habla>
          --library DIR   (default: \(library.path))
        """)
    }
} catch {
    fail("\(error)")
}
