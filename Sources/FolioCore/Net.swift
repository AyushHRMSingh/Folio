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
        c.waitsForConnectivity = false             // offline should say so at once, not hang for minutes
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

    /// `current`, when given, is read at the moment the request queues (no suspension between reading it and
    /// queueing), so a promotion that arrived before the request reached the scheduler is not lost.
    public func run<T: Sendable>(key: String? = nil, priority: FetchPriority, current: (@Sendable () -> FetchPriority)? = nil,
                                 _ op: @Sendable () async throws -> T) async throws -> T {
        try await acquire(key: key, priority: max(priority, current?() ?? priority))
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

/// Everyone asking for the same key at the same time shares one load. It is cancelled only when every
/// caller has gone away (a page scrolled off, read-ahead no longer needed).
final class SharedFetch: @unchecked Sendable {
    static let shared = SharedFetch()
    private final class Entry {
        let task: Task<Data, Error>
        /// Callers still waiting (not cancelled). At zero the load is cancelled.
        var active = 0
        var priority: FetchPriority
        let alias: String?
        init(_ t: Task<Data, Error>, _ p: FetchPriority, _ a: String?) { task = t; priority = p; alias = a }
    }
    private final class PriorityBox: @unchecked Sendable { weak var entry: Entry? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var aliases: [String: String] = [:]

    /// `alias` is another name callers know the image by (the page's own URL), for `promote`.
    /// `op` gets the entry's live priority (raised when a more urgent caller joins), for the scheduler.
    func run(_ key: String, alias: String? = nil,
             _ op: @escaping @Sendable (_ priority: @escaping @Sendable () -> FetchPriority) async throws -> Data) async throws -> Data {
        let p = FetchPriority.current
        let (e, raise): (Entry, Bool) = lock.withLock {
            if let e = entries[key], e.active > 0 {
                e.active += 1
                let raise = p > e.priority
                if raise { e.priority = p }
                return (e, raise)
            }
            let box = PriorityBox()
            let e = Entry(Task { try await op { box.entry?.priority ?? p } }, p, alias)
            box.entry = e
            e.active = 1
            entries[key] = e
            if let alias { aliases[alias] = key }
            return (e, false)
        }
        // A page already waiting as read-ahead that you now look at goes to the front of the line.
        if raise { Task { await FetchScheduler.shared.promote(key: key, to: p) } }
        let result = await withTaskCancellationHandler {
            await e.task.result
        } onCancel: {
            let last: Bool = lock.withLock { e.active -= 1; return e.active == 0 }
            if last { e.task.cancel() }
        }
        lock.withLock {
            if entries[key] === e {
                entries[key] = nil
                if let a = e.alias, aliases[a] == key { aliases[a] = nil }
            }
        }
        return try result.get()
    }

    func promote(alias: String, to p: FetchPriority) {
        let key: String? = lock.withLock {
            guard let k = aliases[alias], let e = entries[k], p > e.priority else { return nil }
            e.priority = p
            return k
        }
        if let key { Task { await FetchScheduler.shared.promote(key: key, to: p) } }
    }
}

/// The image stopped part-way, every time Folio asked.
public struct IncompleteImageError: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "The page arrived incomplete. Click to retry." }
}

/// The source is behind a Cloudflare (or similar) browser check and Folio couldn't pass it.
public struct CloudflareError: LocalizedError, Sendable {
    public var detail: String
    public init(_ detail: String = "") { self.detail = detail }
    public var errorDescription: String? {
        "This site is asking for a Cloudflare check. Complete it in the Verify window Folio opens, then retry."
            + (detail.isEmpty ? "" : " (\(detail))")
    }

    /// Recognises Cloudflare / bot-check wording in an engine error or an HTML body.
    public static func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["cloudflare", "just a moment", "cf-chl", "cf_chl", "attention required", "checking your browser",
                "flaresolverr", "challenge-platform"].contains { t.contains($0) }
    }
}

// MARK: - Backing off a failing source

/// The site said "too many requests". Folio stops asking that source for a while.
public struct RateLimitedError: LocalizedError, Sendable {
    public var retryAfter: TimeInterval?
    public init(retryAfter: TimeInterval? = nil) { self.retryAfter = retryAfter }
    public var errorDescription: String? { "The site says Folio is asking too often (HTTP 429)." }
}

/// A source is resting after repeated failures; nothing was sent.
public struct PausedError: LocalizedError, Sendable {
    public let until: Date
    public init(until: Date) { self.until = until }
    public var errorDescription: String? {
        let m = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return "This source keeps failing, so Folio is giving it a break. It will try again in \(m == 1 ? "a minute" : "\(m) minutes")."
    }
}

/// Stops Folio from hammering a source that keeps failing (which is how sites decide to block you).
/// After `threshold` failures in a row, every request to that source fails at once, without touching the network,
/// for 1 minute, then 2, 4, up to 10 while failures continue. A "too many requests" answer pauses it at once.
/// One success clears it. Missing images (404), cancellations and being offline don't count.
public final class SourceBreaker: @unchecked Sendable {
    public static let shared = SourceBreaker()
    public static let threshold = 4
    private struct State { var fails = 0; var trips = 0; var until: Date? }
    private let lock = NSLock()
    private var states: [String: State] = [:]

    public init() {}

    public func check(_ group: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let u = states[group]?.until, u > Date() { throw PausedError(until: u) }
    }

    public func succeeded(_ group: String) {
        lock.lock(); states[group] = nil; lock.unlock()
    }

    public func failed(_ group: String, _ e: Error) {
        guard Self.counts(e) else { return }
        lock.lock(); defer { lock.unlock() }
        var s = states[group] ?? State()
        if let u = s.until, u > Date() { return }          // already resting
        s.fails += 1
        let limited = e as? RateLimitedError
        if s.fails >= Self.threshold || limited != nil {
            s.trips += 1
            var secs = min(60 * pow(2, Double(s.trips - 1)), 600)
            if let ra = limited?.retryAfter { secs = max(secs, min(ra, 3600)) }
            s.until = Date().addingTimeInterval(secs)
            s.fails = 0
        }
        states[group] = s
    }

    static func counts(_ e: Error) -> Bool {
        if e is CancellationError || e is PausedError { return false }
        if let u = e as? URLError, [.cancelled, .notConnectedToInternet, .dataNotAllowed].contains(u.code) { return false }
        if ((e as? LocalizedError)?.errorDescription ?? "").contains("HTTP 404") { return false }
        return true
    }
}

// MARK: - Retrying fetch

public enum Net {
    // 429 is not here: "too many requests" is answered by stopping (RateLimitedError), never by asking again.
    static let retryableStatus: Set<Int> = [408, 425, 500, 502, 503, 504]
    static let retryableURLErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .notConnectedToInternet, .secureConnectionFailed, .resourceUnavailable,
    ]

    /// GET/POST with bounded retries on transient failures (timeouts, dropped connections, 5xx),
    /// honouring `Retry-After`. A 429 throws `RateLimitedError` at once. Cloudflare check pages are never retried: they won't fix themselves.
    public static func data(for request: URLRequest, session: URLSession = .folio, attempts: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var last: Error = URLError(.unknown)
        for n in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (d, r) = try await session.data(for: request)
                guard let h = r as? HTTPURLResponse else { return (d, HTTPURLResponse()) }
                if h.value(forHTTPHeaderField: "cf-mitigated") == "challenge" { throw CloudflareError("HTTP \(h.statusCode)") }
                if retryableStatus.contains(h.statusCode) || h.statusCode == 403, n < attempts - 1 {
                    // A Cloudflare block never clears by itself on retry: report it at once (the engine sends 500 with
                    // "Cloudflare bypass currently disabled"; sites send 403/503 challenge pages).
                    if CloudflareError.matches(String(decoding: d.prefix(4096), as: UTF8.self)) { throw CloudflareError("HTTP \(h.statusCode)") }
                    if h.statusCode == 403 { return (d, h) }
                    last = URLError(.badServerResponse)
                    try await backoff(n, retryAfter: h.value(forHTTPHeaderField: "Retry-After"))
                    continue
                }
                if h.statusCode == 429 { throw RateLimitedError(retryAfter: h.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)) }
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

    /// `used` = last read (for LRU); `written` = when it was fetched (for max age).
    private struct Entry { var size: Int; var used: Date; var written: Date }
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
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .creationDateKey]
        for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            let n = v.fileSize ?? 0
            index[u.lastPathComponent] = Entry(size: n, used: v.contentModificationDate ?? .distantPast,
                                               written: v.creationDate ?? v.contentModificationDate ?? .distantPast)
            total += n
        }
    }

    public func get(_ key: String, maxAge: TimeInterval? = nil) -> Data? {
        let f = name(key)
        let url = dir.appendingPathComponent(f)
        lock.lock()
        loadIndexLocked()
        guard var e = index[f] else { lock.unlock(); return nil }
        // Stale by when it was fetched, not when it was last looked at (a cover you see daily still refreshes weekly).
        if let maxAge, Date().timeIntervalSince(e.written) > maxAge { lock.unlock(); return nil }
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

    public func remove(_ key: String) {
        let f = name(key)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        lock.lock(); if let old = index.removeValue(forKey: f) { total -= old.size }; lock.unlock()
    }

    public func set(_ key: String, _ data: Data) {
        guard data.count < 64 << 20 else { return }
        let f = name(key)
        do { try data.write(to: dir.appendingPathComponent(f), options: .atomic) } catch { return }
        lock.lock()
        loadIndexLocked()
        if let old = index[f] { total -= old.size }
        index[f] = Entry(size: data.count, used: Date(), written: Date())
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
    /// `group` names the source (or site) for `SourceBreaker`: a source that keeps failing is left alone for a while.
    public static func data(key: String, group: String? = nil, maxAge: TimeInterval? = nil, alias: String? = nil,
                            _ load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let d = DiskCache.shared.get(key, maxAge: maxAge) {
            if !looksLikeImage(d) || isComplete(d) { return d }
            DiskCache.shared.remove(key)                  // a cut-off image cached by an older Folio: fetch it again
        }
        if let group { try SourceBreaker.shared.check(group) }
        // One request per image at a time. Two at once (the reader and the page-shape pass, or a download) make the
        // extension engine write the same temp file twice; one of them then breaks off mid-image.
        return try await SharedFetch.shared.run(key, alias: alias) { prio in try await fetch(key: key, group: group, priority: prio, load) }
    }

    /// Move a queued image (known by its page URL) ahead, e.g. a read-ahead page that just scrolled into view.
    public static func promote(alias: String, to p: FetchPriority) { SharedFetch.shared.promote(alias: alias, to: p) }

    private static func fetch(key: String, group: String?, priority: @escaping @Sendable () -> FetchPriority,
                              _ load: @Sendable () async throws -> Data) async throws -> Data {
        do {
            // A connection that drops mid-image (often between the engine and the site) can still end "successfully":
            // the bytes stop early and the page draws smeared. Ask again, and never keep or show a cut-off image.
            // The wait between tries happens outside the scheduler, so it never holds a slot.
            var got: Data?
            for n in 0..<3 {
                if n > 0 { try await Task.sleep(for: .seconds(0.5 * Double(n))) }
                let d = try await FetchScheduler.shared.run(key: key, priority: FetchPriority.current, current: priority) {
                    // Checked again after waiting in line: the source may have been paused meanwhile.
                    if let group { try SourceBreaker.shared.check(group) }
                    return try await load()
                }
                if !looksLikeImage(d) || isComplete(d) { got = d; break }
            }
            guard let d = got else { throw IncompleteImageError() }
            if looksLikeImage(d) {
                DiskCache.shared.set(key, d)
            } else if CloudflareError.matches(String(decoding: d.prefix(4096), as: UTF8.self)) {
                throw CloudflareError()
            }
            if let group { SourceBreaker.shared.succeeded(group) }
            return d
        } catch {
            if let group { SourceBreaker.shared.failed(group, error) }
            throw error
        }
    }

    /// False when the image's own format says it ends later than the data does (a download cut short).
    /// Formats without a reliable end marker count as complete.
    public static func isComplete(_ d: Data) -> Bool {
        guard d.count > 12 else { return false }
        let b = [UInt8](d.prefix(12))
        let tail = [UInt8](d.suffix(64 << 10))      // some servers pad or append data after the end marker
        func tailHas(_ m: [UInt8]) -> Bool {
            guard tail.count >= m.count else { return false }
            return (0...(tail.count - m.count)).contains { tail[$0..<($0 + m.count)].elementsEqual(m) }
        }
        // (ImageIO can't tell: it reports a cut-off file as complete and decodes the missing part as grey.)
        if b[0] == 0xFF, b[1] == 0xD8 { return tailHas([0xFF, 0xD9]) }                         // JPEG end-of-image
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return tailHas(Array("IEND".utf8)) }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return tail.suffix(8).contains(0x3B) }   // GIF trailer
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            let riff = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24       // WEBP: RIFF size says how long it is
            return d.count >= riff + 8
        }
        return true
    }

    public static func looksLikeImage(_ d: Data) -> Bool {
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
