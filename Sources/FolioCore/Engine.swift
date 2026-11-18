import CryptoKit
import Foundation

/// Runs real Tachiyomi/Mihon Android extensions (e.g. from Keiyoushi) the same way Tachimanga does:
/// through the open-source Suwayomi engine, which converts each extension APK to Java and loads it.
///
/// The engine runs as Folio's child on 127.0.0.1 only, with a random port and random Basic-auth
/// login per launch. Its database, installed extensions, caches, temp files and Java home all
/// live inside Folio's data folder. Only the engine program itself (a public, checksum-verified
/// download) is kept separately in ~/Library/Application Support/FolioEngine.
public final class ExtensionEngine: @unchecked Sendable {
    public static let shared = ExtensionEngine()

    public static let version = "v2.4.2366"
    static let jarSHA256 = "af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd"
    static let jarURL = URL(string: "https://github.com/Suwayomi/Suwayomi-Server/releases/download/\(version)/Suwayomi-Server-\(version).jar")!

    public enum State: Equatable, Sendable {
        case stopped, downloading(Double), starting, running, failed(String)
    }

    private let lock = NSLock()
    private var _state: State = .stopped
    private var process: Process?
    private var port = 0
    private var user = ""
    private var pass = ""
    private var startTask: Task<Void, Error>?
    public var onStateChange: (@Sendable (State) -> Void)?
    /// FlareSolverr endpoint the engine uses to pass Cloudflare checks. Takes effect on the next engine start.
    public var flareSolverrURL = ""

    public var state: State { lock.withLock { _state } }
    private func set(_ s: State) { lock.withLock { _state = s }; onStateChange?(s) }

    // MARK: locations

    /// The engine program is public and identical for everyone. It stays in the real home folder
    /// even when HOME is redirected (e.g. by tests), so it's downloaded only once.
    static var runtimeDir: URL {
        let real = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return Paths.dir(URL(fileURLWithPath: real).appendingPathComponent("Library/Application Support/FolioEngine", isDirectory: true))
    }
    public static var jarFile: URL { runtimeDir.appendingPathComponent("Suwayomi-Server-\(version).jar") }
    /// Everything the engine stores: inside Folio's data folder.
    static var dataDir: URL { Paths.dir(Paths.root.appendingPathComponent("Engine", isDirectory: true)) }
    static var tmpDir: URL { Paths.dir(dataDir.appendingPathComponent("tmp", isDirectory: true)) }

    /// Subfolders of the engine's temp folder that are only caches (pages, thumbnails, HTTP responses).
    /// `Tachidesk/extensions` is not one of them and is never touched.
    static func clearEngineCaches(includingNetwork: Bool) {
        let fm = FileManager.default
        for sub in ["Tachidesk/manga-cache", "Tachidesk/thumbnails"] { try? fm.removeItem(at: tmpDir.appendingPathComponent(sub)) }
        for u in (try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? [] {
            let n = u.lastPathComponent
            if (includingNetwork && n.hasPrefix("tachidesk_network_cache")) || n.hasPrefix("zstd-") { try? fm.removeItem(at: u) }
        }
    }
    public static func cacheSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for sub in ["Tachidesk/manga-cache", "Tachidesk/thumbnails"] { total += Library.size(of: tmpDir.appendingPathComponent(sub)) }
        for u in (try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent.hasPrefix("tachidesk_network_cache") {
            total += Library.size(of: u)
        }
        return total
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.jarFile.path) }

    /// Java 21+ is required. Prefers Homebrew's openjdk@21, then any registered JDK ≥ 21.
    public static func findJava() -> String? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/opt/openjdk@21/bin/java", "/usr/local/opt/openjdk@21/bin/java",
                  "/opt/homebrew/opt/openjdk/bin/java", "/usr/local/opt/openjdk/bin/java"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        p.arguments = ["-v", "21+"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let home = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let java = home + "/bin/java"
        return p.terminationStatus == 0 && fm.isExecutableFile(atPath: java) ? java : nil
    }

    // MARK: lifecycle

    /// Downloads (once) and starts the engine. Safe to call repeatedly.
    public func ensureRunning() async throws {
        if state == .running, process?.isRunning == true { return }
        let task: Task<Void, Error> = lock.withLock {
            if let t = startTask { return t }
            let t = Task { try await self.start() }
            startTask = t
            return t
        }
        do { try await task.value } catch {
            lock.withLock { startTask = nil }
            throw error
        }
    }

    private func start() async throws {
        guard let java = Self.findJava() else {
            let msg = "Extensions need Java 21 or newer. Install it with: brew install openjdk@21"
            set(.failed(msg)); throw FolioError(msg)
        }
        if !isInstalled { try await download() }
        set(.starting)
        Self.clearEngineCaches(includingNetwork: true)          // the engine's page cache is rebuilt on demand

        port = Self.freePort()
        user = "folio"
        pass = UUID().uuidString
        let P = "-Dsuwayomi.tachidesk.config.server."
        let argFile = Self.dataDir.appendingPathComponent("engine.args")
        try? FileManager.default.removeItem(at: argFile)
        guard FileManager.default.createFile(atPath: argFile.path, contents: Data("\(P)authUsername=\(user)\n\(P)authPassword=\(pass)\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            let msg = "Folio couldn\u{2019}t prepare the extension engine\u{2019}s settings."
            set(.failed(msg)); throw FolioError(msg)
        }
        defer { try? FileManager.default.removeItem(at: argFile) }     // Java has read it by the time start() returns
        let args = [
            "-Djava.awt.headless=true", "-XX:-UsePerfData", "-Xmx1g",
            "-Duser.home=\(Paths.home.path)", "-Djava.io.tmpdir=\(Self.tmpDir.path)",
            "\(P)rootDir=\(Self.dataDir.path)",
            "\(P)ip=127.0.0.1", "\(P)port=\(port)",
            "\(P)globalUpdateInterval=0", "\(P)backupInterval=0",        // Folio decides when to check and back up
            "\(P)webUIEnabled=false", "\(P)initialOpenInBrowserEnabled=false", "\(P)systemTrayEnabled=false",
            "\(P)authMode=BASIC_AUTH", "@\(argFile.path)",     // the login goes through a private file, not the command line (`ps` shows every user's arguments)
        ] + (flareSolverrURL.isEmpty ? [] : [
            "\(P)flareSolverrEnabled=true", "\(P)flareSolverrUrl=\(flareSolverrURL)",
            "\(P)flareSolverrTimeout=60", "\(P)flareSolverrAsResponseFallback=true",
        ]) + ["-jar", Self.jarFile.path]
        // A tiny shell supervisor: if Folio dies in any way (even force-quit), the engine is stopped too,
        // so nothing keeps running in the background.
        let quoted = ([java] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = "\(quoted) >'\(Self.dataDir.path)/engine.log' 2>&1 & J=$!; " +
            "trap 'kill $J 2>/dev/null; exit 0' TERM INT HUP; " +
            "while kill -0 \(getpid()) 2>/dev/null && kill -0 $J 2>/dev/null; do sleep 1; done; kill $J 2>/dev/null; wait $J"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = Self.tmpDir.path + "/"
        env["HOME"] = Paths.home.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] dead in
            // Java died (out of memory, crash, killed): forget the finished start, so the next call starts a new engine.
            guard let self else { return }
            self.lock.withLock {
                if self.process === dead { self.startTask = nil }
            }
            if self.process === dead { self.set(.stopped) }
        }
        try p.run()
        process = p

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if !p.isRunning { break }
            if (try? await graphql("{ aboutServer { version } }")) != nil {
                set(.running)
                return
            }
            try await Task.sleep(for: .milliseconds(700))
        }
        stop()
        let log = (try? String(contentsOf: Self.dataDir.appendingPathComponent("engine.log"), encoding: .utf8))?.suffix(400) ?? ""
        let msg = "The extension engine didn't start. \(log)"
        set(.failed(msg)); throw FolioError(msg)
    }

    public func stop() {
        lock.withLock { startTask = nil }
        if let p = process, p.isRunning {
            p.terminate()          // supervisor traps TERM and stops Java
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { usleep(100_000) }
        }
        process = nil
        set(.stopped)
    }

    /// Plain-language reason for a network failure.
    static func describe(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "You appear to be offline. Connect to the internet and try again; the download resumes where it stopped."
            case .timedOut, .networkConnectionLost:
                return "The connection dropped. Try again; the download resumes where it stopped."
            default: break
            }
        }
        return "The engine download failed: \((e as? LocalizedError)?.errorDescription ?? e.localizedDescription)"
    }

    /// Downloads the engine jar. A partly downloaded file is kept and resumed (Range request); the result is
    /// only used after its size and SHA-256 match.
    private func download(retriedFresh: Bool = false) async throws {
        func fail(_ msg: String) -> FolioError { set(.failed(msg)); return FolioError(msg) }
        set(.downloading(0))
        let fm = FileManager.default
        let part = Self.runtimeDir.appendingPathComponent("download.part")
        var have = Int64((try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)??.int64Value ?? 0)
        var req = URLRequest(url: Self.jarURL)
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.folioDownload.bytes(for: req) } catch { throw fail(Self.describe(error)) }
        guard let http = resp as? HTTPURLResponse else { throw fail("The engine download got an unexpected answer.") }
        switch http.statusCode {
        case 200: have = 0                                    // server ignored the range: start over
        case 206: break
        case 416 where !retriedFresh:                         // our partial file doesn't fit: drop it and start fresh
            try? fm.removeItem(at: part)
            return try await download(retriedFresh: true)
        case 403, 429, 500...599:
            throw fail("GitHub is unavailable or is limiting downloads right now (HTTP \(http.statusCode)). Try again in a few minutes.")
        default:
            throw fail("The engine download was refused (HTTP \(http.statusCode)).")
        }
        let remaining = http.expectedContentLength            // -1 when unknown
        let total = remaining > 0 ? Double(Int64(have) + remaining) : 0

        var hasher = SHA256()
        if have > 0 {                                         // resuming: the hash must cover the bytes already on disk
            let r = try FileHandle(forReadingFrom: part); defer { try? r.close() }
            while let chunk = try r.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } else { fm.createFile(atPath: part.path, contents: nil) }
        let h = try FileHandle(forWritingTo: part)
        try h.seekToEnd()
        var buf = Data(); buf.reserveCapacity(1 << 20)
        var got = Double(have), lastReport = 0.0
        do {
            for try await b in bytes {
                buf.append(b)
                if buf.count >= 1 << 20 {
                    try h.write(contentsOf: buf); hasher.update(data: buf); got += Double(buf.count); buf.removeAll(keepingCapacity: true)
                    if total > 0, got / total - lastReport > 0.01 { lastReport = got / total; set(.downloading(lastReport)) }
                }
            }
        } catch {
            try? h.write(contentsOf: buf); try? h.close()     // keep what arrived, so the next try resumes
            throw fail(Self.describe(error))
        }
        try h.write(contentsOf: buf); hasher.update(data: buf); got += Double(buf.count)
        try h.close()
        if total > 0, got != total {
            throw fail("The engine download was cut short. Try again; it resumes where it stopped.")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == Self.jarSHA256 else {
            try? fm.removeItem(at: part)
            throw fail("Engine download failed its integrity check; not using it.")
        }
        try? fm.removeItem(at: Self.jarFile)
        try fm.moveItem(at: part, to: Self.jarFile)
        // A newer pin leaves the old jar behind; it is 183 MB of dead weight.
        for u in (try? fm.contentsOfDirectory(at: Self.runtimeDir, includingPropertiesForKeys: nil)) ?? []
        where u.lastPathComponent.hasPrefix("Suwayomi-Server-") && u.pathExtension == "jar" && u != Self.jarFile {
            try? fm.removeItem(at: u)
        }
    }

    static func freePort() -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: HTTP

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var _baseForTesting: URL { base }
    public func _queryForTesting(_ q: String, _ v: [String: Any] = [:]) async throws -> [String: Any] { try await self.q(q, v) }

    func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        r.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return r
    }

    func graphql(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        var r = request("/api/graphql")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 90
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (d, resp) = try await URLSession.folioLocal.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw FolioError("Extension engine error (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        if let errs = j["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String {
            if CloudflareError.matches(m) { throw CloudflareError() }
            throw FolioError(m.count > 300 ? String(m.prefix(300)) + "…" : m)
        }
        return j["data"] as? [String: Any] ?? [:]
    }

    /// GraphQL once the engine is up.
    func q(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        try await ensureRunning()
        return try await graphql(query, variables)
    }

    public func fetch(_ path: String) async throws -> Data {
        try await ensureRunning()
        let (d, h) = try await Net.data(for: request(path), session: .folioLocal)
        guard (200..<300).contains(h.statusCode) else {
            if CloudflareError.matches(String(decoding: d.prefix(2048), as: UTF8.self)) { throw CloudflareError("HTTP \(h.statusCode)") }
            throw FolioError("Couldn't load image (HTTP \(h.statusCode))")
        }
        return d
    }
}

// MARK: - Repos & extensions

public struct ExtensionRepo: Identifiable, Hashable, Sendable {
    public var name: String
    public var indexURL: String
    public var id: String { indexURL }
}

public struct ExtensionInfo: Identifiable, Hashable, Sendable {
    public var pkgName: String
    public var name: String
    public var lang: String
    public var version: String
    public var installed: Bool
    public var hasUpdate: Bool
    public var obsolete: Bool
    public var nsfw: Bool
    public var iconPath: String?
    public var repo: String?
    public var id: String { pkgName }
}

public struct ExtensionSourceInfo: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var lang: String
    public var displayName: String
    public var supportsLatest: Bool
    public var nsfw: Bool
    public var iconPath: String?
    /// Optional so settings saved before this existed still load.
    public var isConfigurable: Bool?
    public init(id: String, name: String, lang: String, displayName: String, supportsLatest: Bool, nsfw: Bool,
                iconPath: String? = nil, isConfigurable: Bool? = nil) {
        self.id = id; self.name = name; self.lang = lang; self.displayName = displayName
        self.supportsLatest = supportsLatest; self.nsfw = nsfw; self.iconPath = iconPath; self.isConfigurable = isConfigurable
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? id
        lang = c.lenient(String.self, .lang) ?? "all"
        displayName = c.lenient(String.self, .displayName) ?? name
        supportsLatest = c.lenient(Bool.self, .supportsLatest) ?? false
        nsfw = c.lenient(Bool.self, .nsfw) ?? false
        iconPath = c.lenient(String.self, .iconPath)
        isConfigurable = c.lenient(Bool.self, .isConfigurable)
    }
}

// MARK: - Tachiyomi / Mihon / Suwayomi backups

/// A series read from a Tachiyomi-family backup, ready to become a library entry.
public struct ImportedSeries: Sendable {
    public var entry: LibraryEntry
    public var categories: [String]
    /// "sourceID|series URL" as the original app knew it, for matching extra data such as last-read times.
    public var key = ""
}

extension ExtensionEngine {
    /// Restores a `.tachibk` / `.proto.gz` backup through the engine (which reads Tachiyomi's format
    /// natively), then returns what it put in its library. `progress` reports (done, total).
    public func importTachiyomiBackup(_ file: Data, name: String = "backup.tachibk",
                                      progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [ImportedSeries] {
        try await ensureRunning()
        let boundary = "folio-" + UUID().uuidString
        let ops = #"{"query":"mutation($file: Upload!) { restoreBackup(input:{backup:$file}) { id } }","variables":{"file":null}}"#
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"operations\"\r\n\r\n\(ops)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"map\"\r\n\r\n{\"0\":[\"variables.file\"]}\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"0\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(file)
        add("\r\n--\(boundary)--\r\n")
        var r = request("/api/graphql")
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 120
        r.httpBody = body
        let (d, resp) = try await URLSession.folioLocal.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        if let m = ((j["errors"] as? [[String: Any]])?.first?["message"]) as? String { throw FolioError("Couldn\u{2019}t read that backup: \(m)") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let id = (((j["data"] as? [String: Any])?["restoreBackup"]) as? [String: Any])?["id"] as? String else {
            throw FolioError("The engine couldn\u{2019}t start the import.")
        }
        // Poll until the engine reports it is done.
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(500))
            let s = try await graphql("query($id: String!) { restoreStatus(id: $id) { state mangaProgress totalManga } }", ["id": id])
            let st = s["restoreStatus"] as? [String: Any] ?? [:]
            let state = st["state"] as? String ?? ""
            progress?(st["mangaProgress"] as? Int ?? 0, st["totalManga"] as? Int ?? 0)
            if state == "SUCCESS" { break }
            if state == "FAILURE" { throw FolioError("The backup couldn\u{2019}t be restored. It may be from an unsupported version.") }
        }
        return try await libraryFromEngine()
    }

    /// Imports a Tachimanga `.tmb` backup: converts its database, restores it through the engine, and keeps
    /// each series\u{2019} last-read time so Recent looks the way it did.
    public func importTachimangaBackup(_ file: Data, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [ImportedSeries] {
        let proto = try TachimangaBackup.tachiyomiBackup(from: file)
        let last = TachimangaBackup.lastRead(from: file)
        var items = try await importTachiyomiBackup(proto, name: "backup.proto.gz", progress: progress)
        for i in items.indices { if let d = last[items[i].key] { items[i].entry.lastRead = d } }
        return items
    }

    /// Everything the engine currently holds in its library (what a restore just put there).
    public func libraryFromEngine() async throws -> [ImportedSeries] {
        let d = try await q("""
            { mangas(condition:{inLibrary:true}) { nodes { id url title author artist description genre status thumbnailUrl realUrl sourceId
                categories { nodes { name } }
                chapters { nodes { id name chapterNumber uploadDate scanlator realUrl isRead isBookmarked lastPageRead } } } } }
            """)
        let nodes = ((d["mangas"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.map { m in
            let sid = "ext-" + String(describing: m["sourceId"] ?? "")
            let status: SeriesStatus = switch (m["status"] as? String ?? "").uppercased() {
            case "ONGOING": .ongoing; case "COMPLETED", "PUBLISHING_FINISHED": .completed; default: .unknown }
            var s = Series(sourceID: sid, url: String(describing: m["id"] ?? ""), title: m["title"] as? String ?? "",
                           author: m["author"] as? String, artist: m["artist"] as? String, summary: m["description"] as? String,
                           genres: m["genre"] as? [String] ?? [], status: status, coverURL: m["thumbnailUrl"] as? String)
            s.webURL = (m["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let cs = ((m["chapters"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let states: [ChapterState] = cs.map { c in
                let up = (c["uploadDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                let num = (c["chapterNumber"] as? Double).flatMap { $0 >= 0 ? $0 : nil }
                var st = ChapterState(chapter: Chapter(url: String(describing: c["id"] ?? ""), name: c["name"] as? String ?? "", number: num,
                                                      uploaded: (up?.timeIntervalSince1970 ?? 0) > 0 ? up : nil, scanlator: c["scanlator"] as? String,
                                                      webURL: (c["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
                st.read = c["isRead"] as? Bool ?? false
                st.bookmarked = c["isBookmarked"] as? Bool ?? false
                st.lastPage = c["lastPageRead"] as? Int ?? 0
                return st
            }
            let cats = (((m["categories"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return ImportedSeries(entry: LibraryEntry(series: s, chapters: states), categories: cats,
                                  key: "\(m["sourceId"] ?? "")|\(m["url"] ?? "")")
        }
    }
}

extension ExtensionEngine {
    public func repos() async throws -> [ExtensionRepo] {
        let d = try await q("{ extensionStores { nodes { name indexUrl } } }")
        let nodes = ((d["extensionStores"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.map { ExtensionRepo(name: $0["name"] as? String ?? "Repo", indexURL: $0["indexUrl"] as? String ?? "") }
    }

    /// Accepts any Tachiyomi/Mihon-style repo link (index.min.json, repo.json or the repo folder).
    public func addRepo(_ url: String) async throws -> ExtensionRepo {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: clean)?.scheme?.hasPrefix("http") == true else { throw FolioError("Paste the repo's https:// link") }
        let d = try await q("mutation($u: String!) { addExtensionStore(input:{indexUrl:$u}) { extensionStore { name indexUrl } } }", ["u": clean])
        let s = (d["addExtensionStore"] as? [String: Any])?["extensionStore"] as? [String: Any] ?? [:]
        return ExtensionRepo(name: s["name"] as? String ?? "Repo", indexURL: s["indexUrl"] as? String ?? clean)
    }

    public func removeRepo(_ indexURL: String) async throws {
        _ = try await q("mutation($u: String!) { removeExtensionStore(input:{indexUrl:$u}) { clientMutationId } }", ["u": indexURL])
    }

    static let extFields = "pkgName name lang versionName isInstalled hasUpdate isObsolete isNsfw iconUrl repo"

    static func ext(_ e: [String: Any]) -> ExtensionInfo {
        ExtensionInfo(pkgName: e["pkgName"] as? String ?? "", name: e["name"] as? String ?? "", lang: e["lang"] as? String ?? "",
                      version: e["versionName"] as? String ?? "", installed: e["isInstalled"] as? Bool ?? false,
                      hasUpdate: e["hasUpdate"] as? Bool ?? false, obsolete: e["isObsolete"] as? Bool ?? false,
                      nsfw: e["isNsfw"] as? Bool ?? false, iconPath: e["iconUrl"] as? String, repo: e["repo"] as? String)
    }

    /// Re-downloads every repo's index and returns all extensions.
    public func refreshExtensions() async throws -> [ExtensionInfo] {
        let d = try await q("mutation { fetchExtensions(input:{}) { extensions { \(Self.extFields) } } }")
        return (((d["fetchExtensions"] as? [String: Any])?["extensions"] as? [[String: Any]]) ?? []).map(Self.ext)
    }

    public func extensions() async throws -> [ExtensionInfo] {
        let d = try await q("{ extensions { nodes { \(Self.extFields) } } }")
        return (((d["extensions"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).map(Self.ext)
    }

    public enum ExtensionAction: String { case install, update, uninstall }

    public func perform(_ a: ExtensionAction, _ pkg: String) async throws {
        _ = try await q("mutation($id: String!) { updateExtension(input:{id:$id, patch:{\(a.rawValue):true}}) { extension { pkgName } } }", ["id": pkg])
    }

    public func sources() async throws -> [ExtensionSourceInfo] {
        let d = try await q("{ sources { nodes { id name lang displayName supportsLatest isNsfw iconUrl isConfigurable } } }")
        return (((d["sources"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let id = s["id"] as? String, id != "0" else { return nil }   // "0" = engine's own local source
            return ExtensionSourceInfo(id: id, name: s["name"] as? String ?? "", lang: s["lang"] as? String ?? "",
                                       displayName: s["displayName"] as? String ?? "", supportsLatest: s["supportsLatest"] as? Bool ?? false,
                                       nsfw: s["isNsfw"] as? Bool ?? false, iconPath: s["iconUrl"] as? String,
                                       isConfigurable: s["isConfigurable"] as? Bool)
        }
    }
}

// MARK: - A source backed by an installed extension

public final class ExtensionSource: Source, @unchecked Sendable {
    public let info: ExtensionSourceInfo
    let engine: ExtensionEngine
    public var id: String { "ext-" + info.id }
    public var name: String { info.displayName.isEmpty ? info.name : info.displayName }

    public init(_ info: ExtensionSourceInfo, engine: ExtensionEngine = .shared) { self.info = info; self.engine = engine }

    static let mangaFields = "id title author artist description genre status thumbnailUrl realUrl"

    func series(_ m: [String: Any]) -> Series {
        let status: SeriesStatus = switch (m["status"] as? String ?? "").uppercased() {
        case "ONGOING": .ongoing
        case "COMPLETED", "PUBLISHING_FINISHED": .completed
        default: .unknown
        }
        var sr = Series(sourceID: id, url: String(describing: m["id"] ?? ""), title: m["title"] as? String ?? "",
                        author: m["author"] as? String, artist: m["artist"] as? String, summary: m["description"] as? String,
                        genres: m["genre"] as? [String] ?? [], status: status, coverURL: m["thumbnailUrl"] as? String)
        sr.webURL = (m["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return sr
    }

    private func list(_ type: String, _ page: Int, _ query: String?, filters: [SourceFilter] = []) async throws -> SeriesPage {
        var vars: [String: Any] = ["s": info.id, "p": page, "t": type]
        if let query { vars["q"] = query }
        let changes = filters.changes
        if !changes.isEmpty { vars["f"] = changes }
        let d = try await engine.q("""
            mutation($s: LongString!, $p: Int!, $t: FetchSourceMangaType!, $q: String, $f: [FilterChangeInput!]) {
              fetchSourceManga(input:{source:$s, type:$t, page:$p, query:$q, filters:$f}) { hasNextPage mangas { \(Self.mangaFields) } } }
            """, vars)
        let r = d["fetchSourceManga"] as? [String: Any] ?? [:]
        return SeriesPage(series: ((r["mangas"] as? [[String: Any]]) ?? []).map(series), hasNextPage: r["hasNextPage"] as? Bool ?? false)
    }

    public func filters() async throws -> [SourceFilter] {
        func frag(_ nested: String) -> String {
            """
            __typename
            ... on CheckBoxFilter { name cbDefault: default }
            ... on TriStateFilter { name triDefault: default }
            ... on TextFilter { name textDefault: default }
            ... on SelectFilter { name values selDefault: default }
            ... on SortFilter { name values sortDefault: default { index ascending } }
            ... on HeaderFilter { name }
            ... on SeparatorFilter { name }
            \(nested)
            """
        }
        let d = try await engine.q("query($id: LongString!) { source(id: $id) { filters { \(frag("... on GroupFilter { name filters { \(frag("")) } }")) } } }",
                                   ["id": info.id])
        let raw = ((d["source"] as? [String: Any])?["filters"] as? [[String: Any]]) ?? []
        return raw.compactMap(SourceFilter.parse)
    }

    public func preferences() async throws -> [SourcePreference] {
        let d = try await engine.q("query($id: LongString!) { source(id: $id) { preferences { \(SourcePreference.selection) } } }", ["id": info.id])
        return SourcePreference.parseAll(((d["source"] as? [String: Any])?["preferences"] as? [[String: Any]]) ?? [])
    }

    public func setPreference(_ p: SourcePreference) async throws -> [SourcePreference] {
        let d = try await engine.q("""
            mutation($s: LongString!, $c: SourcePreferenceChangeInput!) {
              updateSourcePreference(input:{source:$s, change:$c}) { preferences { \(SourcePreference.selection) } } }
            """, ["s": info.id, "c": p.change])
        return SourcePreference.parseAll(((d["updateSourcePreference"] as? [String: Any])?["preferences"] as? [[String: Any]]) ?? [])
    }

    public func search(_ query: String, filters: [SourceFilter], page: Int) async throws -> SeriesPage {
        try await list("SEARCH", page, query.isEmpty ? nil : query, filters: filters)
    }

    public func popular(page: Int) async throws -> SeriesPage { try await list("POPULAR", page, nil) }
    public func latest(page: Int) async throws -> SeriesPage { try await list("LATEST", page, nil) }
    public func search(_ query: String, page: Int) async throws -> SeriesPage { try await list("SEARCH", page, query) }

    public func details(_ s: Series) async throws -> Series {
        guard let mid = Int(s.url) else { return s }
        let d = try await engine.q("mutation($id: Int!) { fetchManga(input:{id:$id}) { manga { \(Self.mangaFields) } } }", ["id": mid])
        guard let m = (d["fetchManga"] as? [String: Any])?["manga"] as? [String: Any] else { return s }
        return series(m)
    }

    public func chapters(_ s: Series) async throws -> [Chapter] {
        guard let mid = Int(s.url) else { return [] }
        let d = try await engine.q("mutation($id: Int!) { fetchChapters(input:{mangaId:$id}) { chapters { id name chapterNumber uploadDate scanlator realUrl } } }", ["id": mid])
        let cs = ((d["fetchChapters"] as? [String: Any])?["chapters"] as? [[String: Any]]) ?? []
        return cs.map { c in
            let up = (c["uploadDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            let num = (c["chapterNumber"] as? Double).flatMap { $0 >= 0 ? $0 : nil }
            return Chapter(url: String(describing: c["id"] ?? ""), name: c["name"] as? String ?? "", number: num,
                           uploaded: (up?.timeIntervalSince1970 ?? 0) > 0 ? up : nil, scanlator: c["scanlator"] as? String,
                           webURL: (c["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public func pages(_ c: Chapter, of s: Series) async throws -> [PageRef] {
        guard let cid = Int(c.url) else { throw FolioError("Unreadable chapter reference") }
        let d = try await engine.q("mutation($id: Int!) { fetchChapterPages(input:{chapterId:$id}) { pages } }", ["id": cid])
        let ps = ((d["fetchChapterPages"] as? [String: Any])?["pages"] as? [String]) ?? []
        guard !ps.isEmpty else { throw FolioError("The source returned no pages for \(c.name)") }
        // "engine:" refs stay valid even though the engine's port changes between launches.
        return ps.compactMap { URL(string: "engine:" + $0) }.map { .remote($0) }
    }

    public func imageData(_ page: PageRef) async throws -> Data {
        switch page {
        case .file(let u): return try Data(contentsOf: u)
        case .remote(let u):
            let s = u.absoluteString
            let path = s.hasPrefix("engine:") ? String(s.dropFirst(7)) : s
            return try await ImageFetch.data(key: "e|" + path) { [engine] in try await engine.fetch(path) }
        }
    }

    public func coverData(_ s: Series) async throws -> Data? {
        guard let c = s.coverURL, !c.isEmpty else { return nil }
        // Covers can change upstream, so they expire after a week; pages never do.
        return try? await ImageFetch.data(key: "e|" + c, maxAge: 7 * 86400) { [engine] in try await engine.fetch(c) }
    }
}
