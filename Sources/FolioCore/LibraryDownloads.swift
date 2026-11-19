import Foundation

extension Library {
    nonisolated func downloadDir(seriesID: String) -> URL {
        Paths.downloads.appendingPathComponent(Paths.hash(seriesID), isDirectory: true)
    }
    nonisolated func downloadDir(seriesID: String, chapter: String) -> URL {
        downloadDir(seriesID: seriesID).appendingPathComponent(Paths.hash(chapter), isDirectory: true)
    }

    public func download(_ id: String, chapter url: String) async throws {
        guard let e = entry(id), let c = e.chapters.first(where: { $0.chapter.url == url })?.chapter else { return }
        let key = id + "|" + url
        guard !downloading.contains(key) else { return }
        downloading.insert(key)
        defer { downloading.remove(key) }
        let done = downloadDir(seriesID: id, chapter: url).appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: done.path) {      // already complete; just make sure it's flagged
            update(id, url) { c, _ in c.downloaded = true }
            return
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
                for (i, r) in refs.enumerated() {
                    if i >= 4 { try await g.next() }
                    g.addTask {
                        try Task.checkCancellation()
                        let data = try await src.imageData(r)
                        try Task.checkCancellation()
                        try data.write(to: dir.appendingPathComponent(String(format: "%04d.%@", i + 1, Self.ext(of: data))), options: .atomic)
                    }
                }
                try await g.waitForAll()
            }
        }
        try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: dir)       // never leave a half chapter that could be mistaken for a download
            throw error
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".complete").path, contents: nil)
        update(id, url) { c, _ in c.downloaded = true }
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
        let queued = Set(queue.map { $0.id + "|" + $0.url })
        for u in urls where !have.contains(u) && !queued.contains(id + "|" + u) && !downloading.contains(id + "|" + u) {
            queue.append((id, u))
        }
        downloadsPending = queue.count + running
        pump()
    }

    /// Clears the queue and stops the downloads already running; nothing cancelled is marked downloaded.
    public func cancelDownloads() {
        queue.removeAll()
        for t in tasks.values { t.cancel() }
        downloadsPending = running
    }

    private func pump() {
        while running < max(1, settings.parallelDownloads), !queue.isEmpty {
            let job = queue.removeFirst()
            running += 1
            downloadsPending = queue.count + running
            let key = job.id + "|" + job.url
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                do { try await self.download(job.id, chapter: job.url) }
                catch is CancellationError {}
                catch {
                    if Task.isCancelled { self.running -= 1; self.tasks[key] = nil; self.downloadsPending = self.queue.count + self.running; self.pump(); return }
                    let name = self.entry(job.id)?.series.title ?? "a chapter"
                    self.onDownloadError?("Download failed for \(name): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
                self.running -= 1
                self.tasks[key] = nil
                self.downloadsPending = self.queue.count + self.running
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
