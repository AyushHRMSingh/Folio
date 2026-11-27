import Foundation

extension Library {
    nonisolated func downloadDir(seriesID: String) -> URL {
        Paths.downloads.appendingPathComponent(Paths.hash(seriesID), isDirectory: true)
    }
    nonisolated func downloadDir(seriesID: String, chapter: String) -> URL {
        downloadDir(seriesID: seriesID).appendingPathComponent(Paths.hash(chapter), isDirectory: true)
    }

    /// True when pages were fetched; false when the chapter was already on disk. Throws when nothing could be done.
    @discardableResult
    public func download(_ id: String, chapter url: String, progress: ((Int, Int) -> Void)? = nil) async throws -> Bool {
        guard let e = entry(id), let c = e.chapters.first(where: { $0.chapter.url == url })?.chapter else {
            throw FolioError("This series or chapter is no longer in your library.")
        }
        let key = id + "|" + url
        guard !downloading.contains(key) else { throw FolioError("This chapter is already downloading.") }
        downloading.insert(key)
        defer { downloading.remove(key) }
        let done = downloadDir(seriesID: id, chapter: url).appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: done.path) {      // already complete; just make sure it's flagged
            update(id, url) { c, _ in c.downloaded = true }
            return false
        }
        let (src, refs) = try await pages(e.series, c)
        let dir = downloadDir(seriesID: id, chapter: url)
        // Start from an empty folder: a retry must not leave pages from an earlier attempt behind.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
        // Four pages at a time, always behind whatever the reader is loading.
        try await FetchPriority.$current.withValue(.low) {
            try await withThrowingTaskGroup(of: Void.self) { g in
                var done = 0
                progress?(0, refs.count)
                for (i, r) in refs.enumerated() {
                    if i >= 4, try await g.next() != nil { done += 1; progress?(done, refs.count) }
                    g.addTask {
                        try Task.checkCancellation()
                        let data = try await src.imageData(r)
                        try Task.checkCancellation()
                        // An error page or a cut-off image must never be kept as a "downloaded" page.
                        guard ImageFetch.looksLikeImage(data), ImageFetch.isComplete(data) else {
                            throw FolioError("Page \(i + 1) didn\u{2019}t come back as a whole image. Try again later.")
                        }
                        try data.write(to: dir.appendingPathComponent(String(format: "%04d.%@", i + 1, Self.ext(of: data))), options: .atomic)
                    }
                }
                while try await g.next() != nil { done += 1; progress?(done, refs.count) }
            }
        }
        try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: dir)       // never leave a half chapter that could be mistaken for a download
            throw error
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".complete").path, contents: nil)
        update(id, url) { c, _ in c.downloaded = true }
        return true
    }

    public func deleteDownload(_ id: String, chapter url: String) {
        try? FileManager.default.removeItem(at: downloadDir(seriesID: id, chapter: url))
        update(id, url) { c, _ in c.downloaded = false }
    }

    nonisolated static func ext(of d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, String(bytes: b[4...11], encoding: .ascii)?.hasPrefix("ftypavi") == true { return "avif" }
        return "jpg"
    }

    // MARK: download queue

    /// The next `count` chapters you haven't read or downloaded, starting from where you are.
    public func nextToDownload(_ id: String, count: Int?) -> [String] {
        guard let e = entry(id) else { return [] }
        let o = e.ordered
        let start = o.firstIndex { !$0.read } ?? o.count
        let pool = o[start...].filter { !$0.downloaded && !$0.read }
        return (count.map { Array(pool.prefix($0)) } ?? Array(pool)).map(\.chapter.url)
    }

    public func enqueueDownloads(_ id: String, chapters urls: [String]) {
        guard let e = entry(id), e.series.sourceID != "local" else { return }
        let have = Set(e.chapters.filter(\.downloaded).map(\.chapter.url))
        let names = Dictionary(e.chapters.map { ($0.chapter.url, $0.chapter.name) }, uniquingKeysWith: { a, _ in a })
        // A chapter still winding down after being removed may be added again: `pump` waits for its old task.
        for u in urls where !have.contains(u) {
            if let i = downloadJobs.firstIndex(where: { $0.key == id + "|" + u }) {
                if case .failed = downloadJobs[i].state { downloadJobs[i].state = .queued }       // asking again retries it
                continue
            }
            downloadJobs.append(DownloadJob(seriesID: id, chapterURL: u, seriesTitle: e.series.title, chapterName: names[u] ?? u))
        }
        pump()
    }

    /// Clears the queue (failed chapters too) and stops the downloads already running; nothing cancelled is marked downloaded.
    public func cancelDownloads() {
        downloadJobs.removeAll()
        for t in tasks.values { t.cancel() }
        recount()
    }

    /// Stop now; running chapters go back to the front of the queue and start over on resume.
    public func pauseDownloads() {
        guard !downloadsPaused else { return }
        downloadsPaused = true
        for i in downloadJobs.indices where downloadJobs[i].state == .running {
            tasks[downloadJobs[i].key]?.cancel()
            downloadJobs[i].state = .queued; downloadJobs[i].done = 0; downloadJobs[i].total = 0
        }
        recount()
    }

    public func resumeDownloads() {
        downloadsPaused = false
        pump()
    }

    /// Takes one chapter out of the queue, stopping it if it's running.
    public func removeDownload(_ key: String) {
        tasks[key]?.cancel()
        downloadJobs.removeAll { $0.key == key }
        recount(); pump()
    }

    /// Reorder waiting chapters (running ones keep going; order decides what starts next).
    public func moveDownloads(fromOffsets: IndexSet, toOffset: Int) {
        var a = downloadJobs
        let moving = fromOffsets.sorted().map { a[$0] }
        for i in fromOffsets.sorted(by: >) { a.remove(at: i) }
        let dest = toOffset - fromOffsets.filter { $0 < toOffset }.count
        a.insert(contentsOf: moving, at: max(0, min(dest, a.count)))
        downloadJobs = a
    }

    public func moveDownloadToTop(_ key: String) {
        guard let i = downloadJobs.firstIndex(where: { $0.key == key }) else { return }
        let j = downloadJobs.remove(at: i)
        downloadJobs.insert(j, at: downloadJobs.firstIndex { $0.state != .running } ?? downloadJobs.count)
    }

    public func retryDownload(_ key: String) {
        guard let i = downloadJobs.firstIndex(where: { $0.key == key }) else { return }
        downloadJobs[i].state = .queued
        recount(); pump()
    }

    public func retryFailedDownloads() {
        for i in downloadJobs.indices { if case .failed = downloadJobs[i].state { downloadJobs[i].state = .queued } }
        recount(); pump()
    }

    public func clearFailedDownloads() {
        downloadJobs.removeAll { if case .failed = $0.state { true } else { false } }
        recount()
    }

    /// Rough time left: average seconds per chapter this session × chapters left, shared across parallel downloads.
    public var downloadSecondsLeft: Double? {
        guard !downloadsPaused, chapterSeconds.count >= 1 else { return nil }
        let avg = chapterSeconds.suffix(10).reduce(0, +) / Double(min(chapterSeconds.count, 10))
        let left = downloadJobs.reduce(0.0) { n, j in
            switch j.state {
            case .queued: n + 1
            case .running: n + (j.total > 0 ? 1 - Double(j.done) / Double(j.total) : 1)
            case .failed: n
            }
        }
        return left * avg / Double(max(1, settings.parallelDownloads))
    }

    /// Dev only (QA harness): show a made-up queue, paused so nothing runs.
    public func debugShowQueue(_ jobs: [DownloadJob]) {
        downloadsPaused = true
        downloadJobs = jobs
        recount()
    }

    private func recount() {
        downloadsPending = downloadJobs.filter { $0.state == .queued || $0.state == .running }.count
    }

    private func pump() {
        defer { recount() }
        guard !downloadsPaused else { return }
        while tasks.count < max(1, settings.parallelDownloads),
              let i = downloadJobs.firstIndex(where: { $0.state == .queued && tasks[$0.key] == nil }) {   // never restart one still winding down
            downloadJobs[i].state = .running
            let job = downloadJobs[i]
            let key = job.key
            let started = Date()
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                var failure: String?
                var fetched = false
                do {
                    fetched = try await self.download(job.seriesID, chapter: job.chapterURL) { done, total in
                        if let k = self.downloadJobs.firstIndex(where: { $0.key == key }), self.downloadJobs[k].state == .running {
                            self.downloadJobs[k].done = done; self.downloadJobs[k].total = total
                        }
                    }
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { failure = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
                }
                self.tasks[key] = nil
                if let k = self.downloadJobs.firstIndex(where: { $0.key == key }), self.downloadJobs[k].state == .running {
                    if let failure {
                        self.downloadJobs[k].state = .failed(failure)
                        self.onDownloadError?("Download failed for \(job.seriesTitle): \(failure)")
                    } else if !Task.isCancelled {
                        self.downloadJobs.remove(at: k)
                        if fetched { self.chapterSeconds.append(Date().timeIntervalSince(started)) }   // only real downloads time the estimate
                    }
                }
                self.pump()
            }
        }
    }

    /// Deletes offline copies of chapters you've read (when "delete after reading" is on).
    /// Bookmarked chapters are kept; `keeping` protects the chapter that's currently open.
    public func pruneReadDownloads(keeping open: String? = nil) {
        guard settings.deleteAfterRead else { return }
        for e in entries {
            for c in e.chapters where c.downloaded && c.read && !c.bookmarked && c.chapter.url != open {
                deleteDownload(e.id, chapter: c.chapter.url)
            }
        }
    }
}

/// One chapter in the download queue.
public struct DownloadJob: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case queued, running, failed(String) }
    public let seriesID: String
    public let chapterURL: String
    public let seriesTitle: String
    public let chapterName: String
    public var state: State = .queued
    /// Pages saved so far / pages in the chapter (0 until the page list is known).
    public var done = 0
    public var total = 0
    public var key: String { seriesID + "|" + chapterURL }
    public init(seriesID: String, chapterURL: String, seriesTitle: String, chapterName: String, state: State = .queued, done: Int = 0, total: Int = 0) {
        self.seriesID = seriesID; self.chapterURL = chapterURL; self.seriesTitle = seriesTitle; self.chapterName = chapterName
        self.state = state; self.done = done; self.total = total
    }
    public var id: String { key }
}
