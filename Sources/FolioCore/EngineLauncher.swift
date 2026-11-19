import CryptoKit
import Foundation

extension ExtensionEngine {
    // MARK: locations

    /// Lives under the same home as `Paths.home`, so a throwaway HOME gets its own engine folder.
    static var runtimeDir: URL {
        Paths.dir(Paths.home.appendingPathComponent("Library/Application Support/FolioEngine", isDirectory: true))
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
        if ProcessInfo.processInfo.environment["FOLIO_DEBUG_NO_JAVA"] != nil { return nil }     // QA: the no-Java panel
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

    func start() async throws {
        guard let java = Self.findJava() else {
            set(.needsJava); throw FolioError("Extensions need Java 21 or newer, which isn't installed on this Mac.")
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
            "\(P)flareSolverrTimeout=\(flareSolverrTimeoutSeconds)", "\(P)flareSolverrAsResponseFallback=\(flareSolverrResponseFallback)",
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
    func download(retriedFresh: Bool = false) async throws {
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
}
