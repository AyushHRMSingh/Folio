import Combine
import Foundation


public struct ChapterState: Codable, Hashable, Sendable, Identifiable {
    public var chapter: Chapter
    public var read = false
    public var bookmarked = false
    public var lastPage = 0
    public var pageCount: Int?
    public var downloaded = false
    public var lastRead: Date?
    public var fetched = Date()
    /// Remembered so reopening a chapter needs no round-trip to the source. Optional: older files lack them.
    public var pageURLs: [String]?
    public var pagesFetched: Date?
    /// Width/height of each page, learnt while reading, so the layout is right from the first frame next time.
    public var pageAspects: [Float]?
    public var id: String { chapter.url }
    public var started: Bool { lastPage > 0 && !read }
    public init(chapter: Chapter) { self.chapter = chapter }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        chapter = try c.decode(Chapter.self, forKey: .chapter)      // identity: without it the row is meaningless
        read = c.lenient(Bool.self, .read) ?? false
        bookmarked = c.lenient(Bool.self, .bookmarked) ?? false
        lastPage = c.lenient(Int.self, .lastPage) ?? 0
        pageCount = c.lenient(Int.self, .pageCount)
        downloaded = c.lenient(Bool.self, .downloaded) ?? false
        lastRead = c.lenient(Date.self, .lastRead)
        fetched = c.lenient(Date.self, .fetched) ?? Date()
        pageURLs = c.lenient([String].self, .pageURLs)
        pagesFetched = c.lenient(Date.self, .pagesFetched)
        pageAspects = c.lenient([Float].self, .pageAspects)
    }
}

public struct LibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public var series: Series
    public var chapters: [ChapterState]
    public var added = Date()
    public var lastRead: Date?
    public var lastChecked: Date?
    public var readingMode: ReadingMode?
    /// This comic's own reading settings; each nil field follows the library default. nil = all defaults.
    public var reader: ReaderOverrides?
    /// Optional so older library files (without these keys) still load.
    public var categoryIDs: [String]?
    public var note: String?
    /// nil in older files, where every entry was in the library. `false` = read history only.
    public var saved: Bool?
    /// Path of a cover the user picked from a page. Survives refreshes, which would otherwise restore the source's cover.
    public var customCover: String?
    public var isSaved: Bool { saved ?? true }
    public var id: String { series.id }
    public init(series: Series, chapters: [ChapterState], lastChecked: Date? = nil) {
        self.series = series; self.chapters = chapters; self.lastChecked = lastChecked
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        series = try c.decode(Series.self, forKey: .series)         // identity
        chapters = (c.lenient([Lossy<ChapterState>].self, .chapters) ?? []).compactMap(\.value)
        added = c.lenient(Date.self, .added) ?? Date()
        lastRead = c.lenient(Date.self, .lastRead)
        lastChecked = c.lenient(Date.self, .lastChecked)
        readingMode = c.lenient(ReadingMode.self, .readingMode)
        reader = c.lenient(ReaderOverrides.self, .reader)
        categoryIDs = c.lenient([String].self, .categoryIDs)
        note = c.lenient(String.self, .note)
        saved = c.lenient(Bool.self, .saved)
        customCover = c.lenient(String.self, .customCover)
    }
    public var unread: Int { chapters.filter { !$0.read }.count }
    public var downloadedCount: Int { chapters.filter(\.downloaded).count }
    public var latestUpload: Date? { chapters.compactMap(\.chapter.uploaded).max() }
    /// Something fresh to read: unread chapters, the newest uploaded within three days.
    public var hasNew: Bool { unread > 0 && (latestUpload.map { Date().timeIntervalSince($0) < 3 * 86400 } ?? false) }
    public var ordered: [ChapterState] {
        let order = chapters.map(\.chapter).readingOrder().map(\.url)
        let byURL = Dictionary(chapters.map { ($0.chapter.url, $0) }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { byURL[$0] }
    }
    /// Where "Continue" goes: an in-progress chapter, else the first unread, else the last.
    public var resumeChapter: ChapterState? {
        let o = ordered
        if let r = o.filter({ $0.started }).max(by: { ($0.lastRead ?? .distantPast) < ($1.lastRead ?? .distantPast) }) { return r }
        return o.first { !$0.read } ?? o.last
    }
}

struct LibraryFile: Codable {
    var entries: [LibraryEntry] = []
    var settings = FolioSettings()
    /// How many entries were unreadable and left out (not persisted).
    var skipped = 0
    init(entries: [LibraryEntry] = [], settings: FolioSettings = FolioSettings()) { self.entries = entries; self.settings = settings }
    private enum CodingKeys: String, CodingKey { case entries, settings }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([Lossy<LibraryEntry>].self, forKey: .entries) ?? []
        entries = raw.compactMap(\.value)
        skipped = raw.count - entries.count
        settings = c.lenient(FolioSettings.self, .settings) ?? FolioSettings()
    }
}

/// Your saved series and reading state. Persisted as one JSON file in Folio's data folder.
@MainActor
public final class Library: ObservableObject {
    @Published public internal(set) var entries: [LibraryEntry] = []
    @Published public var settings = FolioSettings() { didSet { scheduleSave() } }
    @Published public internal(set) var downloading: Set<String> = []
    /// Chapters waiting for or in the middle of a download (queue + running; failed ones not counted).
    @Published public internal(set) var downloadsPending = 0
    /// The download queue in order: running, waiting and failed chapters. The Downloads page shows it.
    @Published public internal(set) var downloadJobs: [DownloadJob] = []
    /// While paused nothing starts; chapters that were running go back to waiting at the front.
    @Published public internal(set) var downloadsPaused = false
    public var onDownloadError: ((String) -> Void)?
    var tasks: [String: Task<Void, Never>] = [:]
    /// Page-list requests in flight, one per chapter: the reader and a download asking at once share it
    /// (the engine stores the list as it fetches; two at once can trip over each other).
    var pageListLoads: [String: PageListLoad] = [:]
    /// One shared page-list request and how many callers still want it (cancelled when none do).
    final class PageListLoad { let task: Task<[PageRef], Error>; var active = 1; init(_ t: Task<[PageRef], Error>) { task = t } }
    /// Seconds each finished chapter took this session, for the time-left estimate.
    var chapterSeconds: [Double] = []

    public let local: LocalSource
    var opds: [String: OPDSSource] = [:]
    let file: URL

    let writer: LibraryWriter
    /// Set when library.json existed but couldn't be read at all. Folio then refuses to overwrite it
    /// (a copy is kept as `library.corrupt-<date>.json`) until the user acts: `startFresh()`.
    @Published public internal(set) var loadProblem: String?
    /// Entries that were unreadable and left out when loading (the rest loaded normally).
    public internal(set) var skippedOnLoad = 0

    public init(file: URL = Paths.libraryFile, local: LocalSource = LocalSource()) {
        self.file = file
        self.local = local
        self.writer = LibraryWriter.shared(for: file)
        writer.flush()                        // anything still waiting to be written must be on disk before we read
        if let d = try? Data(contentsOf: file) {
            do {
                let lf = try JSONDecoder.folio.decode(LibraryFile.self, from: d)
                // Older versions stored a comic's mode even when it was just the default; such comics follow the default.
                entries = lf.entries.map { var e = $0; if e.readingMode == lf.settings.defaultMode { e.readingMode = nil }; return e }
                settings = lf.settings
                skippedOnLoad = lf.skipped
                if lf.skipped > 0 { keepCorruptCopy(d) }
            } catch {
                keepCorruptCopy(d)
                loadProblem = "Folio couldn\u{2019}t read your library file. A copy was kept next to it as library.corrupt-*.json, and nothing will be saved until you choose what to do."
                writer.blockWrites = true
            }
        }
    }

    private func keepCorruptCopy(_ d: Data) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let dir = file.deletingLastPathComponent()
        var url = dir.appendingPathComponent("library.corrupt-\(f.string(from: Date())).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("library.corrupt-\(f.string(from: Date()))-\(n).json"); n += 1 }
        try? d.write(to: url, options: .atomic)
    }

    /// After a load problem: begin with an empty library (the corrupt copy stays on disk) and resume saving.
    public func startFresh() { loadProblem = nil; writer.blockWrites = false; entries = []; settings = FolioSettings(); save() }

    /// Writes the library now (used when quitting).
    public func save() {
        writer.set(LibraryFile(entries: entries, settings: settings))
        writer.flush()
    }

    /// Everything else saves through here: changes within 0.4 s are merged into one write, and the
    /// JSON is encoded and written on a background queue — a page turn never waits on the disk.
    func scheduleSave() { writer.schedule(LibraryFile(entries: entries, settings: settings)) }

    // MARK: sources

    public var sources: [Source] {
        [local] + settings.servers.map { opdsSource($0) } + settings.extensionSources.map { extensionSource($0) } + _sourcesForTesting
    }
    /// foliotest only: extra sources (e.g. one that counts requests).
    public var _sourcesForTesting: [Source] = []

    var ext: [String: ExtensionSource] = [:]
    public func extensionSource(_ i: ExtensionSourceInfo) -> ExtensionSource {
        if let e = ext[i.id], e.info == i { return e }
        let s = ExtensionSource(i); ext[i.id] = s; return s
    }

    /// Extension sources the user wants to see (by language / 18+ preference).
    public var visibleExtensionSources: [ExtensionSource] {
        settings.extensionSources
            .filter { settings.languages.isEmpty || settings.languages.contains($0.lang) }
            .filter { settings.showNSFW || !$0.nsfw }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { extensionSource($0) }
    }

    /// Re-reads installed extensions' sources from the engine.
    public func syncExtensionSources() async throws {
        let s = try await ExtensionEngine.shared.sources()
        if s != settings.extensionSources { settings.extensionSources = s }
    }

    public func opdsSource(_ s: OPDSServer) -> OPDSSource {
        if let existing = opds[s.id], existing.server == s { return existing }
        let src = OPDSSource(s); opds[s.id] = src; return src
    }

    public func source(_ id: String) -> Source? { sources.first { $0.id == id } }

    // MARK: library membership

    public func entry(_ id: String) -> LibraryEntry? { entries.first { $0.id == id } ?? passing[id] }
    /// Incognito: series being read that aren't in the library or history. Kept in memory only, so the reader can
    /// still find chapters (next, previous, endless scrolling between chapters), and never written to disk.
    private var passing: [String: LibraryEntry] = [:]
    /// In the library (saved) — as opposed to merely having been read.
    public func contains(_ s: Series) -> Bool { entry(s.id)?.isSaved == true }
    public var savedEntries: [LibraryEntry] { entries.filter { $0.isSaved && !isBlacklisted($0.series) } }

    /// Saves a series to the library (a series you've only read becomes saved, keeping its progress).
    @discardableResult
    public func add(_ s: Series) async throws -> LibraryEntry {
        if var e = entry(s.id) {
            if !e.isSaved { e.saved = true; replace(e) }
            return entry(s.id) ?? e
        }
        return try await create(s, saved: true)
    }

    /// Makes sure a series has an entry so reading it keeps progress and shows in Recent, without saving it.
    @discardableResult
    public func track(_ s: Series) async throws -> LibraryEntry {
        if let e = entry(s.id) { return e }
        return try await create(s, saved: false, persist: !settings.incognito)   // incognito: no history entry
    }

    func create(_ s: Series, saved: Bool, persist: Bool = true) async throws -> LibraryEntry {
        guard let src = source(s.sourceID) else { throw FolioError("Source not available") }
        let full = (try? await src.details(s)) ?? s
        let chs = try await src.chapters(full)
        if let e = entry(s.id) { return e }     // raced with another add
        var e = LibraryEntry(series: full, chapters: chs.map { ChapterState(chapter: $0) }, lastChecked: Date())
        e.saved = saved
        if !persist { passing[e.id] = e; return e }
        entries.append(e)
        scheduleSave()
        return e
    }

    /// Takes a series out of the library. If you've read it, it stays in Recent (history) with its progress.
    public func remove(_ id: String) {
        guard var e = entry(id) else { return }
        if e.lastRead != nil && e.isSaved {
            e.saved = false
            e.categoryIDs = nil
            replace(e)
        } else {
            entries.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: downloadDir(seriesID: id))
            scheduleSave()
        }
    }

    // MARK: migration

    /// Carries read marks, bookmarks and page progress from `old` chapters onto `new` ones, matching by chapter
    /// number (so "Ch. 12" on one source meets "Chapter 12" on another), then by exact name.
    public static func transferProgress(from old: [ChapterState], to new: [ChapterState]) -> [ChapterState] {
        func key(_ n: Double) -> Int { Int((n * 100).rounded()) }
        var byNumber: [Int: [ChapterState]] = [:], byName: [String: [ChapterState]] = [:]
        for o in old {
            if o.chapter.number >= 0 { byNumber[key(o.chapter.number), default: []].append(o) }
            byName[o.chapter.name.lowercased().trimmingCharacters(in: .whitespaces), default: []].append(o)
        }
        return new.map { n in
            var out = n
            let matches = (n.chapter.number >= 0 ? byNumber[key(n.chapter.number)] : nil)
                ?? byName[n.chapter.name.lowercased().trimmingCharacters(in: .whitespaces)] ?? []
            guard !matches.isEmpty else { return out }
            out.read = matches.contains { $0.read }
            out.bookmarked = matches.contains { $0.bookmarked }
            out.lastPage = matches.map(\.lastPage).max() ?? 0
            return out
        }
    }

    /// Moves a series to another source: the new one is added, takes over progress, categories and notes, and
    /// the old one is removed unless `keepOriginal`. Returns the new entry.
    @discardableResult
    public func migrate(_ oldID: String, to target: Series, keepOriginal: Bool) async throws -> LibraryEntry {
        guard let old = entry(oldID) else { throw FolioError("That series isn\u{2019}t in your library.") }
        guard target.id != oldID else { throw FolioError("That is the same series.") }
        var e = try await add(target)
        e.chapters = Self.transferProgress(from: old.chapters, to: e.chapters)
        e.lastRead = old.lastRead
        e.added = old.added
        e.categoryIDs = old.categoryIDs
        e.readingMode = old.readingMode
        e.reader = old.reader
        e.note = old.note
        e.saved = true
        replace(e)
        if !keepOriginal {
            entries.removeAll { $0.id == oldID }
            try? FileManager.default.removeItem(at: downloadDir(seriesID: oldID))
            scheduleSave()
        }
        return entry(e.id) ?? e
    }

    /// Drops a series from read history. Saved series stay in the library; others disappear entirely.
    public func forget(_ id: String) {
        guard var e = entry(id) else { return }
        if e.isSaved { e.lastRead = nil; replace(e) } else {
            entries.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: downloadDir(seriesID: id))
            scheduleSave()
        }
    }

    // MARK: updates

    /// Re-asks the source for chapters; new ones are added unread. Returns how many are new.
    @discardableResult
    public func refresh(_ id: String) async throws -> Int {
        guard let e = entry(id), let src = source(e.series.sourceID) else { return 0 }
        let fresh = try await src.chapters(e.series)
        let details = (try? await src.details(e.series)) ?? e.series
        guard var cur = entry(id) else { return 0 }
        let known = Set(cur.chapters.map(\.chapter.url))
        let added = fresh.filter { !known.contains($0.url) }
        let freshByURL = Dictionary(fresh.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for i in cur.chapters.indices { if let f = freshByURL[cur.chapters[i].chapter.url] { cur.chapters[i].chapter = f } }
        cur.chapters += added.map { ChapterState(chapter: $0) }
        cur.series = details
        if let c = cur.customCover { cur.series.coverURL = c }
        cur.lastChecked = Date()
        replace(cur)
        return added.count
    }

    /// Uses `jpeg` as this series' cover (a page the user picked).
    public func setCover(_ id: String, jpeg: Data) {
        guard var e = entry(id) else { return }
        let name = UUID().uuidString + ".jpg"
        let url = Paths.covers.appendingPathComponent(name)
        guard (try? jpeg.write(to: url)) != nil else { return }
        if let old = e.customCover { try? FileManager.default.removeItem(atPath: old) }
        e.customCover = url.path
        e.series.coverURL = url.path
        replace(e)
    }

    /// Library series an automatic check should look at, after the skip rules.
    public func updatable() -> [LibraryEntry] {
        let r = settings.updateRules
        return savedEntries.filter { e in
            if r.skipCompleted && e.series.status.isFinished { return false }
            if r.skipWithUnread && e.unread > 0 { return false }
            if r.skipNotStarted && !e.chapters.contains(where: { $0.read || $0.started }) { return false }
            if let cats = e.categoryIDs, cats.contains(where: r.excludedCategories.contains) { return false }
            return true
        }
    }

    /// Whether the schedule says a check is due. `launch` is only evaluated at start-up (`atLaunch`).
    public func updateDue(now: Date = Date(), atLaunch: Bool = false) -> Bool {
        let i = settings.updateInterval
        guard let gap = i.seconds, i != .off, atLaunch || i.repeats else { return false }
        return settings.lastAutoUpdate.map { now.timeIntervalSince($0) >= gap } ?? true
    }

    /// Scheduled check: stamps `lastAutoUpdate` only if something was refreshed (or there was nothing to refresh).
    public func runScheduledRefresh() async -> (new: Int, failed: [String]) {
        let n = updatable().count
        let r = await refreshAll(onlyRulesApply: true)
        if n == 0 || r.failed.count < n { settings.lastAutoUpdate = Date() }
        return r
    }

    public func refreshAll(onlyRulesApply: Bool = false) async -> (new: Int, failed: [String]) {
        var total = 0, failed: [String] = []
        for e in (onlyRulesApply ? updatable() : savedEntries) {
            do { total += try await refresh(e.id) } catch { failed.append(e.series.title) }
        }
        return (total, failed)
    }

    // MARK: reading state

    func replace(_ e: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e; scheduleSave() }
        else if passing[e.id] != nil {
            // Saving a series you were reading incognito puts it in the library for real.
            if e.isSaved { passing[e.id] = nil; entries.append(e); scheduleSave() } else { passing[e.id] = e }
        }
    }

    func update(_ id: String, _ url: String, _ f: (inout ChapterState, inout LibraryEntry) -> Void) {
        guard var e = entry(id), let i = e.chapters.firstIndex(where: { $0.chapter.url == url }) else { return }
        var c = e.chapters[i]
        f(&c, &e)
        e.chapters[i] = c
        replace(e)
    }

    public func setProgress(_ id: String, chapter url: String, page: Int, of count: Int) {
        if settings.incognito { return }   // incognito: nothing about reading is recorded
        update(id, url) { c, e in
            c.lastPage = page
            c.pageCount = count
            c.lastRead = Date()
            if page >= count - 1 { c.read = true }
            e.lastRead = Date()
        }
    }

    public func setRead(_ id: String, chapters urls: [String], _ read: Bool) {
        guard var e = entry(id) else { return }
        for i in e.chapters.indices where urls.contains(e.chapters[i].chapter.url) {
            e.chapters[i].read = read
            if !read { e.chapters[i].lastPage = 0 }
        }
        replace(e)
    }

    public func setBookmarked(_ id: String, chapter url: String, _ on: Bool) { update(id, url) { c, _ in c.bookmarked = on } }

    /// Stores a per-comic mode only when it differs from the default, so changing the default later still
    /// applies to comics that never chose otherwise.
    public func setMode(_ id: String, _ mode: ReadingMode?) {
        guard var e = entry(id) else { return }
        e.readingMode = mode == settings.defaultMode ? nil : mode
        replace(e)
    }

    // MARK: per-comic reading settings

    /// The reading settings in effect for one comic: its own choices over the library defaults.
    public func readerPrefs(for id: String?) -> ReaderPrefs {
        let o = id.flatMap { entry($0)?.reader } ?? ReaderOverrides()
        let s = settings
        return ReaderPrefs(
            mode: id.map { mode(for: $0) } ?? s.defaultMode,
            webtoonWidth: o.webtoonWidth ?? s.webtoonWidth, pageGap: o.pageGap ?? s.pageGap,
            readerBackground: o.readerBackground ?? s.readerBackground, autoScrollSpeed: o.autoScrollSpeed ?? s.autoScrollSpeed,
            seamlessChapters: o.seamlessChapters ?? s.seamlessChapters, tapZones: o.tapZones ?? s.tapZones,
            invertTapZones: o.invertTapZones ?? s.invertTapZones, doublePage: o.doublePage ?? s.doublePage,
            doubleFirstAlone: o.doubleFirstAlone ?? s.doubleFirstAlone, splitWidePages: o.splitWidePages ?? s.splitWidePages,
            cropBorders: o.cropBorders ?? s.cropBorders)
    }

    /// Sets one reading setting. With a comic (that's in the library or history) it becomes that comic's own value —
    /// stored only while it differs from the default; with no comic it changes the default for every comic.
    public func setReaderPref<T: Equatable>(_ id: String?, _ own: WritableKeyPath<ReaderOverrides, T?>,
                                            _ def: WritableKeyPath<FolioSettings, T>, _ value: T) {
        guard let id, var e = entry(id) else { settings[keyPath: def] = value; return }
        var o = e.reader ?? ReaderOverrides()
        o[keyPath: own] = value == settings[keyPath: def] ? nil : value
        e.reader = o.isEmpty ? nil : o
        replace(e)
    }

    /// The comic's own value for a setting, or nil when it follows the default.
    public func readerOverride<T>(_ id: String?, _ own: KeyPath<ReaderOverrides, T?>) -> T? {
        id.flatMap { entry($0)?.reader?[keyPath: own] }
    }

    public func resetReaderPref<T>(_ id: String, _ own: WritableKeyPath<ReaderOverrides, T?>) {
        guard var e = entry(id), var o = e.reader else { return }
        o[keyPath: own] = nil
        e.reader = o.isEmpty ? nil : o
        replace(e)
    }

    /// Makes this comic's settings the default for every comic, and clears its own choices (it now matches).
    public func useReaderPrefsAsDefault(_ id: String) {
        let p = readerPrefs(for: id)
        var s = settings
        s.defaultMode = p.mode; s.webtoonWidth = p.webtoonWidth; s.pageGap = p.pageGap
        s.readerBackground = p.readerBackground; s.autoScrollSpeed = p.autoScrollSpeed
        s.seamlessChapters = p.seamlessChapters; s.tapZones = p.tapZones; s.invertTapZones = p.invertTapZones
        s.doublePage = p.doublePage; s.doubleFirstAlone = p.doubleFirstAlone; s.splitWidePages = p.splitWidePages
        s.cropBorders = p.cropBorders
        settings = s
        guard var e = entry(id) else { return }
        e.reader = nil; e.readingMode = nil
        replace(e)
    }

    /// Does this comic have any settings of its own?
    public func hasOwnReaderPrefs(_ id: String) -> Bool {
        guard let e = entry(id) else { return false }
        return e.reader != nil || e.readingMode != nil
    }

    public func mode(for id: String) -> ReadingMode { entry(id)?.readingMode ?? settings.defaultMode }

    /// Chapter after `url` in reading order.
    public func next(after url: String, in id: String, skipRead: Bool = false) -> Chapter? {
        guard let o = entry(id)?.ordered, let i = o.firstIndex(where: { $0.chapter.url == url }), i + 1 < o.count else { return nil }
        return o[(i + 1)...].first { !skipRead || !$0.read }?.chapter
    }

    public func previous(before url: String, in id: String, skipRead: Bool = false) -> Chapter? {
        guard let o = entry(id)?.ordered, let i = o.firstIndex(where: { $0.chapter.url == url }), i > 0 else { return nil }
        return o[..<i].last { !skipRead || !$0.read }?.chapter
    }

    /// Recently read, newest first.
    public var recents: [LibraryEntry] {
        entries.filter { $0.lastRead != nil && !isBlacklisted($0.series) }.sorted { $0.lastRead! > $1.lastRead! }
    }

    // MARK: blacklist

    /// Lowercased letters and digits only, so "Solo Leveling!" and "solo-leveling" match.
    public static func titleKey(_ t: String) -> String {
        String(t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Hidden by id, or by the same title on any source.
    public func isBlacklisted(_ s: Series) -> Bool {
        let bl = settings.blacklist
        guard !bl.isEmpty else { return false }
        if bl.contains(where: { $0.id == s.id }) { return true }
        let k = Self.titleKey(s.title)
        return !k.isEmpty && bl.contains { Self.titleKey($0.title) == k }
    }

    /// Never show this series again: it leaves the library and history (downloads deleted) and is hidden everywhere.
    public func blacklist(_ s: Series) {
        guard !settings.blacklist.contains(where: { $0.id == s.id }) else { return }
        if entry(s.id) != nil {
            entries.removeAll { $0.id == s.id }
            try? FileManager.default.removeItem(at: downloadDir(seriesID: s.id))
        }
        settings.blacklist.append(BlacklistedSeries(s))       // saves
    }

    public func unblacklist(_ id: String) { settings.blacklist.removeAll { $0.id == id } }

    // MARK: pages + downloads (offline copies, kept in Folio's private data folder)

    public func pages(_ s: Series, _ c: Chapter) async throws -> (Source, [PageRef]) {
        guard let src = source(s.sourceID) else { throw FolioError("Source \(s.sourceID) is not configured") }
        let dir = downloadDir(seriesID: s.id, chapter: c.url)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path) {
            let files = Archive.images(in: dir)
            if !files.isEmpty { return (src, files.map { .file($0) }) }
        }
        // Page lists are remembered for a week (sources can rotate signed image links; Retry in the reader forgets them sooner).
        if let st = entry(s.id)?.chapters.first(where: { $0.chapter.url == c.url }),
           let urls = st.pageURLs, !urls.isEmpty, let at = st.pagesFetched, Date().timeIntervalSince(at) < 7 * 86400 {
            let refs = urls.compactMap { URL(string: $0) }.map { PageRef.remote($0) }
            if refs.count == urls.count { return (src, refs) }
        }
        let k = s.id + "|" + c.url
        let load: PageListLoad
        if let l = pageListLoads[k], l.active > 0 { l.active += 1; load = l } else {
            load = PageListLoad(Task { try await src.pages(c, of: s) })
            pageListLoads[k] = load
        }
        let result = await withTaskCancellationHandler {
            await load.task.result
        } onCancel: {
            Task { @MainActor in
                load.active -= 1
                if load.active == 0 { load.task.cancel() }     // the reader closed and no download wants it either
            }
        }
        if pageListLoads[k] === load { pageListLoads[k] = nil }
        try Task.checkCancellation()
        let refs = try result.get()
        let remote = refs.compactMap { r -> String? in if case .remote(let u) = r { u.absoluteString } else { nil } }
        if remote.count == refs.count && !settings.incognito { update(s.id, c.url) { st, _ in st.pageURLs = remote; st.pagesFetched = Date(); st.pageCount = remote.count } }
        return (src, refs)
    }

    /// Drop the remembered page list (e.g. after a failed load) so the next open asks the source again.
    public func forgetPages(_ id: String, chapter url: String) {
        update(id, url) { st, _ in st.pageURLs = nil; st.pagesFetched = nil; st.pageAspects = nil }
    }

    public func pageAspects(_ id: String, chapter url: String) -> [Float]? {
        entry(id)?.chapters.first { $0.chapter.url == url }?.pageAspects
    }

    public func setPageAspects(_ id: String, chapter url: String, _ a: [Float]) {
        guard !settings.incognito, pageAspects(id, chapter: url) != a else { return }
        update(id, url) { st, _ in st.pageAspects = a }
    }

    // MARK: categories

    @discardableResult
    public func addCategory(_ name: String) -> LibraryCategory? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !settings.categories.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) else { return nil }
        let c = LibraryCategory(name: n)
        settings.categories.append(c)
        return c
    }

    public func renameCategory(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = settings.categories.firstIndex(where: { $0.id == id }) else { return }
        settings.categories[i].name = n
    }

    public func deleteCategory(_ id: String) {
        settings.categories.removeAll { $0.id == id }
        for i in entries.indices {
            entries[i].categoryIDs?.removeAll { $0 == id }
            if entries[i].categoryIDs?.isEmpty == true { entries[i].categoryIDs = nil }
        }
        scheduleSave()
    }

    public func moveCategory(_ id: String, by delta: Int) {
        guard let i = settings.categories.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard settings.categories.indices.contains(j) else { return }
        settings.categories.swapAt(i, j)
    }

    public func setCategories(_ id: String, _ ids: [String]) {
        guard var e = entry(id) else { return }
        var seen = Set<String>()
        let u = ids.filter { seen.insert($0).inserted }
        e.categoryIDs = u.isEmpty ? nil : u
        replace(e)
    }

    public func count(in category: String?) -> Int {
        guard let category else { return savedEntries.count }
        return savedEntries.filter { $0.categoryIDs?.contains(category) == true }.count
    }

    // MARK: library view (filter + sort), kept in core so it's testable

    public func browse(category: String? = nil, query: String = "") -> [LibraryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var list = entries.filter { e in
            e.isSaved && !isBlacklisted(e.series) && (category == nil || e.categoryIDs?.contains(category!) == true)
                && (q.isEmpty || e.series.title.localizedCaseInsensitiveContains(q) || (e.series.author ?? "").localizedCaseInsensitiveContains(q))
                && settings.filters.matches(e)
        }
        let asc = settings.sortAscending
        func num<T: Comparable>(_ x: T, _ y: T) -> Bool? { x == y ? nil : (asc ? x < y : x > y) }
        func text(_ x: String, _ y: String) -> Bool? {
            let r = x.localizedStandardCompare(y)
            return r == .orderedSame ? nil : (asc ? r == .orderedAscending : r == .orderedDescending)
        }
        func progress(_ e: LibraryEntry) -> Double { e.chapters.isEmpty ? 0 : Double(e.chapters.count - e.unread) / Double(e.chapters.count) }
        let mode = settings.librarySort
        list.sort { a, b in
            let primary: Bool? = switch mode {
            case .lastRead: num(a.lastRead ?? a.added, b.lastRead ?? b.added)
            case .added: num(a.added, b.added)
            case .unread: num(a.unread, b.unread)
            case .chapterCount: num(a.chapters.count, b.chapters.count)
            case .latestChapter: num(a.latestUpload ?? .distantPast, b.latestUpload ?? .distantPast)
            case .downloaded: num(a.downloadedCount, b.downloadedCount)
            case .progress: num(progress(a), progress(b))
            case .title: text(a.series.title, b.series.title)
            case .author: text(a.series.author ?? "\u{FFFF}", b.series.author ?? "\u{FFFF}")
            case .source: text(a.series.sourceID, b.series.sourceID)
            }
            if let primary { return primary }
            return a.series.title.localizedStandardCompare(b.series.title) == .orderedAscending     // ties: alphabetical
        }
        return list
    }

    public func randomEntry() -> LibraryEntry? { savedEntries.filter { $0.unread > 0 }.randomElement() ?? savedEntries.randomElement() }

    public func markAll(_ id: String, read: Bool) {
        guard let e = entry(id) else { return }
        setRead(id, chapters: e.chapters.map(\.chapter.url), read)
    }

    // MARK: history & privacy

    /// Clears the "Recent" list (not your reading progress).
    public func clearHistory(olderThan age: TimeInterval? = nil) {
        let cutoff = age.map { Date().addingTimeInterval(-$0) }
        for i in entries.indices {
            guard let d = entries[i].lastRead else { continue }
            if cutoff == nil || d < cutoff! { entries[i].lastRead = nil }
        }
        // Series that were only ever read (never saved) have nothing left to keep.
        for e in entries where !e.isSaved && e.lastRead == nil { try? FileManager.default.removeItem(at: downloadDir(seriesID: e.id)) }
        entries.removeAll { !$0.isSaved && $0.lastRead == nil }
        scheduleSave()
    }

    // MARK: test hook
    public func _replaceEntries(_ e: [LibraryEntry]) { entries = e; save() }
}

extension JSONEncoder {
    static let folio: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
}
extension JSONDecoder {
    static let folio: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}


/// Coalescing, off-main writer for library.json. One per file.
final class LibraryWriter: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var all: [String: LibraryWriter] = [:]
    static func shared(for file: URL) -> LibraryWriter {
        lock.lock(); defer { lock.unlock() }
        if let w = all[file.path] { return w }
        let w = LibraryWriter(file); all[file.path] = w; return w
    }

    let file: URL
    private let queue = DispatchQueue(label: "folio.library.writer", qos: .utility)
    private let lock = NSLock()
    private var pending: LibraryFile?
    private var armed = false
    private var _block = false
    /// While true nothing is written (the file on disk couldn't be read, so it must not be overwritten).
    var blockWrites: Bool { get { lock.lock(); defer { lock.unlock() }; return _block } set { lock.lock(); _block = newValue; lock.unlock() } }

    init(_ file: URL) { self.file = file }

    func set(_ lf: LibraryFile) { lock.lock(); pending = lf; lock.unlock() }

    func schedule(_ lf: LibraryFile) {
        lock.lock()
        pending = lf
        let arm = !armed
        armed = true
        lock.unlock()
        if arm { queue.asyncAfter(deadline: .now() + 0.4) { [self] in drain() } }
    }

    /// Synchronous: waits for any write in flight, then writes what's pending.
    func flush() { queue.sync { drain() } }

    private func drain() {
        lock.lock()
        let lf = pending
        pending = nil
        armed = false
        lock.unlock()
        guard let lf, !blockWrites, let d = try? JSONEncoder.folio.encode(lf) else { return }
        // Keep one previous copy, so a bad write or a bug can never be the only version.
        let bak = file.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: file, to: bak)
        }
        try? d.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
