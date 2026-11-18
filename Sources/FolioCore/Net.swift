import CryptoKit
import Foundation

// MARK: - Sessions

public extension URLSession {
    /// Folio's own requests to the outside world (OPDS servers, engine download).
    /// No URLCache, no cookies persisted: nothing is stored outside Folio's data folder.
    static let folio: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpAdditionalHeaders = ["User-Agent": "Folio/1.0"]
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 180
        c.httpMaximumConnectionsPerHost = 8
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    /// The 183 MB engine download: no overall time limit (a slow connection must still finish), no waiting
    /// silently for connectivity (offline should say so at once). Progress is kept on disk and resumed.
    static let folioDownload: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpAdditionalHeaders = ["User-Agent": "Folio/1.0"]
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 24 * 3600
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Talks to the extension engine on 127.0.0.1. The engine fetches upstream pages itself, so
    /// requests can legitimately take a while, but connecting never should. Many parallel
    /// connections are fine on loopback.
    static let folioLocal: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 75
        c.timeoutIntervalForResource = 240
        c.httpMaximumConnectionsPerHost = 16
        c.connectionProxyDictionary = [:]          // never route loopback through a system proxy
        return URLSession(configuration: c)
    }()
}

// MARK: - Priority & scheduler

public enum FetchPriority: Int, Comparable, Sendable {
    case low = 0, normal = 1, high = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Set around a load so `Source` implementations don't need to know about scheduling.
    @TaskLocal public static var current: FetchPriority = .normal
}

/// Caps how many page/cover requests run at once and decides who goes next:
/// high priority first (newest request first — it's what the user is looking at now),
/// then normal, then low (oldest first, so read-ahead fetches the nearest page first).
/// Waiting requests can be cancelled or promoted.
public actor FetchScheduler {
    public static let shared = FetchScheduler(limit: 6)

    private struct Waiter {
        let id: UInt64
        let key: String?
        var priority: FetchPriority
        var seq: UInt64
        let cont: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var running = 0
    private var waiters: [Waiter] = []
    private var counter: UInt64 = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(key: String? = nil, priority: FetchPriority,
                                 _ op: @Sendable () async throws -> T) async throws -> T {
        try await acquire(key: key, priority: priority)
        defer { release() }
        return try await op()
    }

    /// Bump a queued request (e.g. a read-ahead page that just scrolled into view).
    public func promote(key: String, to p: FetchPriority) {
        for i in waiters.indices where waiters[i].key == key && waiters[i].priority < p {
            counter += 1
            waiters[i].priority = p
            waiters[i].seq = counter          // newest request of its class: goes first
        }
    }

    private func acquire(key: String?, priority: FetchPriority) async throws {
        try Task.checkCancellation()
        if running < limit && waiters.isEmpty { running += 1; return }
        counter += 1
        let id = counter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, key: key, priority: priority, seq: id, cont: c))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: CancellationError())
    }

    private func release() {
        running -= 1
        guard !waiters.isEmpty else { return }
        var best = 0
        for i in 1..<waiters.count {
            let a = waiters[i], b = waiters[best]
            if a.priority != b.priority { if a.priority > b.priority { best = i }; continue }
            if a.priority == .low ? a.seq < b.seq : a.seq > b.seq { best = i }
        }
        running += 1
        waiters.remove(at: best).cont.resume()
    }
}

// MARK: - Errors

/// The source is behind a Cloudflare (or similar) browser check and Folio couldn't pass it.
public struct CloudflareError: LocalizedError, Sendable {
    public var detail: String
    public init(_ detail: String = "") { self.detail = detail }
    public var errorDescription: String? {
        "This source is behind a Cloudflare check. Set a FlareSolverr address in Settings → Network to pass it, or try again later."
            + (detail.isEmpty ? "" : " (\(detail))")
    }

    /// Recognises Cloudflare / bot-check wording in an engine error or an HTML body.
    public static func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["cloudflare", "just a moment", "cf-chl", "cf_chl", "attention required", "checking your browser",
                "flaresolverr", "challenge-platform"].contains { t.contains($0) }
    }
}

// MARK: - Retrying fetch

public enum Net {
    static let retryableStatus: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
    static let retryableURLErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet, .secureConnectionFailed, .resourceUnavailable,
    ]

    /// GET/POST with bounded retries on transient failures (timeouts, dropped connections, 429/5xx),
    /// honouring `Retry-After`. Cloudflare check pages are never retried: they won't fix themselves.
    public static func data(for request: URLRequest, session: URLSession = .folio, attempts: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var last: Error = URLError(.unknown)
        for n in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (d, r) = try await session.data(for: request)
                guard let h = r as? HTTPURLResponse else { return (d, HTTPURLResponse()) }
                if h.value(forHTTPHeaderField: "cf-mitigated") == "challenge" { throw CloudflareError("HTTP \(h.statusCode)") }
                if retryableStatus.contains(h.statusCode), n < attempts - 1 {
                    if (h.statusCode == 503 || h.statusCode == 403),
                       CloudflareError.matches(String(decoding: d.prefix(2048), as: UTF8.self)) { throw CloudflareError("HTTP \(h.statusCode)") }
                    last = URLError(.badServerResponse)
                    try await backoff(n, retryAfter: h.value(forHTTPHeaderField: "Retry-After"))
                    continue
                }
                return (d, h)
            } catch let e as URLError where retryableURLErrors.contains(e.code) && n < attempts - 1 {
                last = e
                try await backoff(n, retryAfter: nil)
            }
        }
        throw last
    }

    private static func backoff(_ n: Int, retryAfter: String?) async throws {
        var s = 0.4 * pow(2, Double(n)) + Double.random(in: 0...0.25)
        if let ra = retryAfter, let secs = Double(ra) { s = min(max(s, secs), 8) }
        try await Task.sleep(for: .seconds(s))
    }
}

// MARK: - Disk cache

/// Byte cache for page images and covers under Folio's data folder. Least-recently-used files are
/// dropped once the folder passes its size limit. Covers can carry a max age; pages never expire.
public final class DiskCache: @unchecked Sendable {
    public static let shared = DiskCache(dir: Paths.cache.appendingPathComponent("net", isDirectory: true), limit: 1 << 30)

    private struct Entry { var size: Int; var used: Date }
    private let dir: URL
    private let limit: Int
    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var total = 0
    private var loaded = false

    public init(dir: URL, limit: Int) {
        self.dir = dir
        self.limit = limit
        Paths.dir(dir)
    }

    private func name(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func loadIndexLocked() {
        guard !loaded else { return }
        loaded = true
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            let n = v.fileSize ?? 0
            index[u.lastPathComponent] = Entry(size: n, used: v.contentModificationDate ?? .distantPast)
            total += n
        }
    }

    public func get(_ key: String, maxAge: TimeInterval? = nil) -> Data? {
        let f = name(key)
        let url = dir.appendingPathComponent(f)
        lock.lock()
        loadIndexLocked()
        guard var e = index[f] else { lock.unlock(); return nil }
        if let maxAge, Date().timeIntervalSince(e.used) > maxAge { lock.unlock(); return nil }   // stale: refetch and overwrite
        lock.unlock()
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            lock.lock(); if let old = index.removeValue(forKey: f) { total -= old.size }; lock.unlock()
            return nil
        }
        // Recency for LRU; skip the write when it's already fresh (most reads).
        if Date().timeIntervalSince(e.used) > 600 {
            e.used = Date()
            try? FileManager.default.setAttributes([.modificationDate: e.used], ofItemAtPath: url.path)
            lock.lock(); index[f] = e; lock.unlock()
        }
        return d
    }

    public func set(_ key: String, _ data: Data) {
        guard data.count < 64 << 20 else { return }
        let f = name(key)
        do { try data.write(to: dir.appendingPathComponent(f), options: .atomic) } catch { return }
        lock.lock()
        loadIndexLocked()
        if let old = index[f] { total -= old.size }
        index[f] = Entry(size: data.count, used: Date())
        total += data.count
        let over = total > limit
        lock.unlock()
        if over { trim() }
    }

    private func trim() {
        lock.lock(); defer { lock.unlock() }
        var victims: [String] = []
        var size = total
        for (k, e) in index.sorted(by: { $0.value.used < $1.value.used }) {
            if size <= limit * 9 / 10 { break }
            victims.append(k); size -= e.size
        }
        for k in victims {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(k))
            index[k] = nil
        }
        total = size
    }

    public var byteCount: Int { lock.lock(); defer { lock.unlock() }; loadIndexLocked(); return total }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dir)
        Paths.dir(dir)
        index = [:]; total = 0; loaded = true
    }
}

// MARK: - Image pipeline

public enum ImageFetch {
    /// Disk cache → scheduler (bounded, prioritised) → network, then store. Anything that isn't
    /// an image (an HTML error or challenge page) is never cached and is reported properly.
    public static func data(key: String, maxAge: TimeInterval? = nil,
                            _ load: @Sendable () async throws -> Data) async throws -> Data {
        if let d = DiskCache.shared.get(key, maxAge: maxAge) { return d }
        let d = try await FetchScheduler.shared.run(key: key, priority: FetchPriority.current) {
            try await load()
        }
        if looksLikeImage(d) {
            DiskCache.shared.set(key, d)
        } else if CloudflareError.matches(String(decoding: d.prefix(4096), as: UTF8.self)) {
            throw CloudflareError()
        }
        return d
    }

    static func looksLikeImage(_ d: Data) -> Bool {
        guard d.count > 12 else { return false }
        let b = [UInt8](d.prefix(12))
        if b[0] == 0xFF, b[1] == 0xD8 { return true }                                         // JPEG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }             // PNG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                           // GIF
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }           // WEBP
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true }             // AVIF / HEIC
        if b[0] == 0x42, b[1] == 0x4D { return true }                                         // BMP
        if b[0] == 0xFF, b[1] == 0x0A { return true }                                         // JXL
        if b[0] == 0x00, b[1] == 0x00, b[2] == 0x00, b[3] == 0x0C, b[4] == 0x4A { return true } // JXL container
        return false
    }
}
