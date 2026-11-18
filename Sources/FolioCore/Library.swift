import Combine
import Foundation


extension KeyedDecodingContainer {
    /// Decodes a value, or nil when the key is missing, the wrong type, or an enum value this version doesn't know.
    /// One odd field must never cost the user their library.
    func lenient<T: Decodable>(_ t: T.Type, _ k: Key) -> T? { (try? decodeIfPresent(t, forKey: k)) ?? nil }
}

/// Decodes to nil instead of throwing, so one bad element doesn't fail a whole array.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from d: Decoder) throws { value = try? T(from: d) }
}

public enum ReadingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case webtoon, rightToLeft, leftToRight
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .webtoon: "Webtoon (vertical scroll)"
        case .rightToLeft: "Paged, right to left (manga)"
        case .leftToRight: "Paged, left to right"
        }
    }
    public var shortLabel: String {
        switch self { case .webtoon: "Webtoon"; case .rightToLeft: "Paged ←"; case .leftToRight: "Paged →" }
    }
}

public enum ReaderBackground: String, Codable, CaseIterable, Sendable, Identifiable {
    case black, gray, white, auto
    public var id: String { rawValue }
}

/// Where a click lands in the paged reader. `left`/`right` turn pages, `middle` toggles controls.
public enum TapZones: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard, edges, lShaped, off
    public var id: String { rawValue }
    public var label: String { switch self { case .standard: "Thirds"; case .edges: "Edges"; case .lShaped: "L-shaped"; case .off: "Off" } }
    public enum Action: Sendable { case back, forward, controls }
    /// `x`, `y` are 0...1 within the visible page (y from the top).
    public func action(x: Double, y: Double) -> Action {
        switch self {
        case .standard: return x < 1.0 / 3 ? .back : (x > 2.0 / 3 ? .forward : .controls)
        case .edges: return x < 0.15 ? .back : (x > 0.85 ? .forward : .controls)
        case .lShaped:
            if x < 1.0 / 3 && y > 0.2 { return .back }
            if y > 2.0 / 3 { return .forward }
            if x > 2.0 / 3 { return .forward }
            return .controls
        case .off: return .controls
        }
    }
}

public struct LibraryCategory: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String = UUID().uuidString, name: String) { self.id = id; self.name = name }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? UUID().uuidString
        name = c.lenient(String.self, .name) ?? "Category"
    }
}

public enum LibraryDisplay: String, Codable, CaseIterable, Sendable, Identifiable {
    case grid, compact, list
    public var id: String { rawValue }
    public var label: String { switch self { case .grid: "Grid"; case .compact: "Compact grid"; case .list: "List" } }
    public var icon: String { switch self { case .grid: "square.grid.2x2"; case .compact: "square.grid.3x3"; case .list: "list.bullet" } }
}

public enum GridGap: String, Codable, CaseIterable, Sendable, Identifiable {
    case tight, normal, loose
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
    public var points: Double { switch self { case .tight: 6; case .normal: 14; case .loose: 24 } }
}

public enum CardTitles: String, Codable, CaseIterable, Sendable, Identifiable {
    case below, hover, off
    public var id: String { rawValue }
    public var label: String { switch self { case .below: "Below"; case .hover: "On hover"; case .off: "Off" } }
}

public enum LibrarySort: String, Codable, CaseIterable, Sendable, Identifiable {
    case lastRead, title, unread, chapterCount, latestChapter, added, downloaded, progress, author, source
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .lastRead: "Last read"; case .title: "Alphabetical"; case .unread: "Unread chapters"
        case .chapterCount: "Chapter count"; case .latestChapter: "Latest update"; case .added: "Date added"
        case .downloaded: "Downloaded"; case .progress: "Reading progress"; case .author: "Author"; case .source: "Source"
        }
    }
    /// Words for the two directions, e.g. "a → z" / "z → a".
    public var ascendingLabel: String {
        switch self {
        case .title, .author, .source: "a → z"
        case .lastRead, .latestChapter, .added: "oldest first"
        case .unread, .chapterCount, .downloaded, .progress: "fewest first"
        }
    }
    public var descendingLabel: String {
        switch self {
        case .title, .author, .source: "z → a"
        case .lastRead, .latestChapter, .added: "newest first"
        case .unread, .chapterCount, .downloaded, .progress: "most first"
        }
    }
    /// The direction that makes sense when you first pick this sort.
    public var naturalAscending: Bool {
        switch self { case .title, .author, .source: true; default: false }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Library filters: every enabled one must match.
public struct LibraryFilters: Codable, Hashable, Sendable {
    public var unread = false
    public var downloaded = false
    public var started = false
    public var bookmarked = false
    public var completed = false
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        unread = c.lenient(Bool.self, .unread) ?? false
        downloaded = c.lenient(Bool.self, .downloaded) ?? false
        started = c.lenient(Bool.self, .started) ?? false
        bookmarked = c.lenient(Bool.self, .bookmarked) ?? false
        completed = c.lenient(Bool.self, .completed) ?? false
    }
    public var active: Bool { unread || downloaded || started || bookmarked || completed }
    public func matches(_ e: LibraryEntry) -> Bool {
        (!unread || e.unread > 0)
            && (!downloaded || e.chapters.contains { $0.downloaded })
            && (!started || e.chapters.contains { $0.started || $0.read })
            && (!bookmarked || e.chapters.contains { $0.bookmarked })
            && (!completed || e.series.status == .completed)
    }
}

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

/// How often Folio checks your library for new chapters on its own.
public enum UpdateInterval: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, launch, hours6, hours12, daily, hours48, weekly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: "Never"; case .launch: "When Folio opens"; case .hours6: "Every 6 hours"; case .hours12: "Every 12 hours"
        case .daily: "Every day"; case .hours48: "Every 2 days"; case .weekly: "Every week"
        }
    }
    /// Gap between checks. `launch` checks at start-up at most every 6 hours; `off` never.
    public var seconds: TimeInterval? {
        switch self {
        case .off: nil; case .launch: 6 * 3600; case .hours6: 6 * 3600; case .hours12: 12 * 3600
        case .daily: 86400; case .hours48: 2 * 86400; case .weekly: 7 * 86400
        }
    }
    /// Keeps checking while Folio stays open (everything except never / on-open).
    public var repeats: Bool { self != .off && self != .launch }
}

/// Which series automatic checks leave alone (the library's own update button always checks everything).
public struct UpdateRules: Codable, Sendable, Equatable {
    public var skipWithUnread = false
    public var skipNotStarted = false
    public var skipCompleted = false
    public var excludedCategories: [String] = []
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        skipWithUnread = c.lenient(Bool.self, .skipWithUnread) ?? false
        skipNotStarted = c.lenient(Bool.self, .skipNotStarted) ?? false
        skipCompleted = c.lenient(Bool.self, .skipCompleted) ?? false
        excludedCategories = c.lenient([String].self, .excludedCategories) ?? []
    }
}

public struct FolioSettings: Codable, Sendable {
    public var servers: [OPDSServer] = []
    public var defaultMode: ReadingMode = .webtoon
    public var preloadPages = 4
    // Reader
    public var webtoonWidth: Double = 0.62        // fraction of the window used by the strip (laptop-friendly side margins)
    public var pageGap: Double = 0                // points between webtoon pages
    public var readerBackground: ReaderBackground = .black
    public var autoScrollSpeed: Double = 140      // points per second
    public var keepAwake = true
    public var showPageNumber = false
    public var hideSavedInBrowse = false          // Browse: leave out series already in the library
    public var pageNumberReset = true             // one-time migration flag: page counter went off by default
    public var seamlessChapters = true            // webtoon: continue straight into the next chapter
    public var doublePage = false                 // paged: two pages side by side, like a book
    public var doubleFirstAlone = true            // the first page is a cover and stands alone
    public var splitWidePages = false             // single-page: a wide spread is shown as two halves
    public var cropBorders = false                // paged: zoom away plain white/black page margins
    public var autoBackup = true                  // a dated backup each day Folio opens
    public var backupsKept = 5
    public var lastAutoBackup: Date?
    public var tapZones: TapZones = .standard
    public var invertTapZones = false
    public var skipReadChapters = false           // next/previous chapter jumps over chapters already read
    public var settingsVersion = 2
    /// Last known sources from installed extensions (so the library works before the engine is up).
    public var extensionSources: [ExtensionSourceInfo] = []
    /// Languages shown for extensions/sources ("all" = multi-language sources).
    public var languages: [String] = ["en", "all"]
    public var showNSFW = true
    // Library
    public var categories: [LibraryCategory] = []
    public var libraryDisplay: LibraryDisplay = .grid
    public var gridSize: Double = 150             // minimum cover width
    public var gridColumns: Int?                  // nil = as many as fit; otherwise exactly this many
    public var gridGap: GridGap = .normal
    public var cardTitles: CardTitles = .below
    public var librarySort: LibrarySort = .lastRead
    public var sortAscending = false
    public var filters = LibraryFilters()
    public var showBadges = true                  // unread counter
    public var showDownloadBadge = true
    public var showNewTag = false                 // 'new' on series with unread chapters uploaded in the last 3 days
    // Updates & downloads
    public var autoUpdateOnLaunch = true          // superseded by updateInterval; still read from older files
    public var updateInterval: UpdateInterval = .launch
    public var updateRules = UpdateRules()
    public var lastAutoUpdate: Date?
    public var deleteAfterRead = false
    public var parallelDownloads = 2
    // Privacy & look
    public var incognito = false
    public var appearance: AppearanceMode = .system
    // Network
    /// FlareSolverr address (e.g. http://127.0.0.1:8191/v1). Empty = off. Lets the engine pass Cloudflare checks.
    public var flareSolverrURL = ""

    public init() {}
    public init(from d: Decoder) throws {   // tolerant: older files lack newer keys
        let c = try d.container(keyedBy: CodingKeys.self)
        servers = c.lenient([OPDSServer].self, .servers) ?? []
        defaultMode = c.lenient(ReadingMode.self, .defaultMode) ?? .webtoon
        preloadPages = c.lenient(Int.self, .preloadPages) ?? 4
        webtoonWidth = c.lenient(Double.self, .webtoonWidth) ?? 0.62
        pageGap = c.lenient(Double.self, .pageGap) ?? 0
        readerBackground = c.lenient(ReaderBackground.self, .readerBackground) ?? .black
        autoScrollSpeed = c.lenient(Double.self, .autoScrollSpeed) ?? 140
        keepAwake = c.lenient(Bool.self, .keepAwake) ?? true
        let migrated = c.lenient(Bool.self, .pageNumberReset) ?? false
        showPageNumber = migrated ? (c.lenient(Bool.self, .showPageNumber) ?? false) : false
        pageNumberReset = true
        hideSavedInBrowse = c.lenient(Bool.self, .hideSavedInBrowse) ?? false
        seamlessChapters = c.lenient(Bool.self, .seamlessChapters) ?? true
        doublePage = c.lenient(Bool.self, .doublePage) ?? false
        doubleFirstAlone = c.lenient(Bool.self, .doubleFirstAlone) ?? true
        splitWidePages = c.lenient(Bool.self, .splitWidePages) ?? false
        cropBorders = c.lenient(Bool.self, .cropBorders) ?? false
        autoBackup = c.lenient(Bool.self, .autoBackup) ?? true
        backupsKept = c.lenient(Int.self, .backupsKept) ?? 5
        lastAutoBackup = c.lenient(Date.self, .lastAutoBackup)
        tapZones = c.lenient(TapZones.self, .tapZones) ?? .standard
        invertTapZones = c.lenient(Bool.self, .invertTapZones) ?? false
        skipReadChapters = c.lenient(Bool.self, .skipReadChapters) ?? false
        settingsVersion = c.lenient(Int.self, .settingsVersion) ?? 1
        if settingsVersion < 2 { defaultMode = .webtoon; settingsVersion = 2 }   // webtoon is now the primary mode
        extensionSources = c.lenient([ExtensionSourceInfo].self, .extensionSources) ?? []
        languages = c.lenient([String].self, .languages) ?? ["en", "all"]
        showNSFW = c.lenient(Bool.self, .showNSFW) ?? true
        categories = c.lenient([LibraryCategory].self, .categories) ?? []
        libraryDisplay = c.lenient(LibraryDisplay.self, .libraryDisplay) ?? .grid
        gridSize = c.lenient(Double.self, .gridSize) ?? 150
        gridColumns = c.lenient(Int.self, .gridColumns)
        gridGap = c.lenient(GridGap.self, .gridGap) ?? .normal
        cardTitles = c.lenient(CardTitles.self, .cardTitles) ?? .below
        librarySort = c.lenient(LibrarySort.self, .librarySort) ?? .lastRead
        sortAscending = c.lenient(Bool.self, .sortAscending) ?? false
        filters = c.lenient(LibraryFilters.self, .filters) ?? LibraryFilters()
        showBadges = c.lenient(Bool.self, .showBadges) ?? true
        showDownloadBadge = c.lenient(Bool.self, .showDownloadBadge) ?? true
        showNewTag = c.lenient(Bool.self, .showNewTag) ?? false
        autoUpdateOnLaunch = c.lenient(Bool.self, .autoUpdateOnLaunch) ?? true
        updateInterval = c.lenient(UpdateInterval.self, .updateInterval) ?? (autoUpdateOnLaunch ? .launch : .off)
        updateRules = c.lenient(UpdateRules.self, .updateRules) ?? UpdateRules()
        lastAutoUpdate = c.lenient(Date.self, .lastAutoUpdate)
        deleteAfterRead = c.lenient(Bool.self, .deleteAfterRead) ?? false
        parallelDownloads = c.lenient(Int.self, .parallelDownloads) ?? 2
        incognito = c.lenient(Bool.self, .incognito) ?? false
        appearance = c.lenient(AppearanceMode.self, .appearance) ?? .system
        flareSolverrURL = c.lenient(String.self, .flareSolverrURL) ?? ""
    }
}

struct BackupFile: Codable {
    static let formatName = "folio-backup"
    var format = BackupFile.formatName
    var version = 1
    var created: Date
    var library: LibraryFile
    var covers: [String: Data] = [:]
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
    @Published public private(set) var entries: [LibraryEntry] = []
    @Published public var settings = FolioSettings() { didSet { scheduleSave() } }
    @Published public private(set) var downloading: Set<String> = []
    /// Chapters waiting for or in the middle of a download (queue + running).
    @Published public private(set) var downloadsPending = 0
    public var onDownloadError: ((String) -> Void)?
    private var queue: [(id: String, url: String)] = []
    private var running = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    public let local: LocalSource
    private var opds: [String: OPDSSource] = [:]
    private let file: URL

    private let writer: LibraryWriter
    /// Set when library.json existed but couldn't be read at all. Folio then refuses to overwrite it
    /// (a copy is kept as `library.corrupt-<date>.json`) until the user acts: `startFresh()`.
    @Published public private(set) var loadProblem: String?
    /// Entries that were unreadable and left out when loading (the rest loaded normally).
    public private(set) var skippedOnLoad = 0

    public init(file: URL = Paths.libraryFile, local: LocalSource = LocalSource()) {
        self.file = file
        self.local = local
        self.writer = LibraryWriter.shared(for: file)
        writer.flush()                        // anything still waiting to be written must be on disk before we read
        if let d = try? Data(contentsOf: file) {
            do {
                let lf = try JSONDecoder.folio.decode(LibraryFile.self, from: d)
                entries = lf.entries
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

    // MARK: backup

    /// Your library, reading progress, categories, settings and picked covers as one file.
    public func backupData() throws -> Data {
        var covers: [String: Data] = [:]
        for e in entries { if let c = e.customCover, let d = try? Data(contentsOf: URL(fileURLWithPath: c)) { covers[(c as NSString).lastPathComponent] = d } }
        let b = BackupFile(created: Date(), library: LibraryFile(entries: entries, settings: settings), covers: covers)
        return try JSONEncoder.folio.encode(b)
    }

    /// Replaces the library with a backup. Returns how many series came back. Downloads aren't in backups,
    /// so restored chapters are marked not-downloaded.
    @discardableResult
    public func restore(_ data: Data) throws -> Int {
        guard let b = try? JSONDecoder.folio.decode(BackupFile.self, from: data), b.format == BackupFile.formatName else {
            throw FolioError("That isn\u{2019}t a Folio backup.")
        }
        var lib = b.library
        for (name, d) in b.covers { try? d.write(to: Paths.covers.appendingPathComponent(name)) }
        for i in lib.entries.indices {
            if let c = lib.entries[i].customCover {
                let path = Paths.covers.appendingPathComponent((c as NSString).lastPathComponent).path
                lib.entries[i].customCover = path; lib.entries[i].series.coverURL = path
            }
            for k in lib.entries[i].chapters.indices where lib.entries[i].chapters[k].downloaded {
                let dir = downloadDir(seriesID: lib.entries[i].series.id, chapter: lib.entries[i].chapters[k].chapter.url)
                if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path) { lib.entries[i].chapters[k].downloaded = false }
            }
        }
        entries = lib.entries
        settings = lib.settings
        save()
        return entries.count
    }

    /// Adds series read from a Tachiyomi-family backup. Series already in the library are left alone.
    /// Categories are matched by name and created when missing.
    @discardableResult
    public func importSeries(_ items: [ImportedSeries]) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for item in items {
            if entry(item.entry.id) != nil { skipped += 1; continue }
            var e = item.entry
            e.saved = true
            e.added = Date()
            var ids: [String] = []
            for name in item.categories where !name.isEmpty {
                if let c = settings.categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { ids.append(c.id) }
                else { let c = LibraryCategory(name: name); settings.categories.append(c); ids.append(c.id) }
            }
            if !ids.isEmpty { e.categoryIDs = ids }
            entries.append(e)
            added += 1
        }
        if added > 0 { scheduleSave() }
        return (added, skipped)
    }

    /// Saves a dated backup into Folio's Backups folder and prunes old ones. Returns its URL.
    @discardableResult
    public func writeAutoBackup(keep: Int = 5) -> URL? {
        guard let d = try? backupData() else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = Paths.backups.appendingPathComponent("folio-\(f.string(from: Date())).foliobackup")
        guard (try? d.write(to: url)) != nil else { return nil }
        let all = ((try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "foliobackup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: old) }
        return url
    }

    /// Newest automatic backup, if any.
    public var latestAutoBackup: (url: URL, date: Date)? {
        let all = ((try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "foliobackup" }
        return all.compactMap { u in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (u, $0) } }
            .max { $0.1 < $1.1 }
    }

    /// Everything else saves through here: changes within 0.4 s are merged into one write, and the
    /// JSON is encoded and written on a background queue — a page turn never waits on the disk.
    private func scheduleSave() { writer.schedule(LibraryFile(entries: entries, settings: settings)) }

    // MARK: sources

    public var sources: [Source] {
        [local] + settings.servers.map { opdsSource($0) } + settings.extensionSources.map { extensionSource($0) }
    }

    private var ext: [String: ExtensionSource] = [:]
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

    public func entry(_ id: String) -> LibraryEntry? { entries.first { $0.id == id } }
    /// In the library (saved) — as opposed to merely having been read.
    public func contains(_ s: Series) -> Bool { entry(s.id)?.isSaved == true }
    public var savedEntries: [LibraryEntry] { entries.filter(\.isSaved) }

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
        return try await create(s, saved: false)
    }

    private func create(_ s: Series, saved: Bool) async throws -> LibraryEntry {
        guard let src = source(s.sourceID) else { throw FolioError("Source not available") }
        let full = (try? await src.details(s)) ?? s
        let chs = try await src.chapters(full)
        if let e = entry(s.id) { return e }     // raced with another add
        var e = LibraryEntry(series: full, chapters: chs.map { ChapterState(chapter: $0) }, lastChecked: Date())
        e.saved = saved
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
            if r.skipCompleted && e.series.status == .completed { return false }
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

    public func refreshAll(onlyRulesApply: Bool = false) async -> (new: Int, failed: [String]) {
        var total = 0, failed: [String] = []
        for e in (onlyRulesApply ? updatable() : savedEntries) {
            do { total += try await refresh(e.id) } catch { failed.append(e.series.title) }
        }
        return (total, failed)
    }

    // MARK: reading state

    private func replace(_ e: LibraryEntry) {
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e; scheduleSave() }
    }

    private func update(_ id: String, _ url: String, _ f: (inout ChapterState, inout LibraryEntry) -> Void) {
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

    public func setMode(_ id: String, _ mode: ReadingMode?) {
        guard var e = entry(id) else { return }
        e.readingMode = mode
        replace(e)
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
        entries.filter { $0.lastRead != nil }.sorted { $0.lastRead! > $1.lastRead! }
    }

    // MARK: pages + downloads (offline copies, kept in Folio's private data folder)

    nonisolated func downloadDir(seriesID: String) -> URL {
        Paths.downloads.appendingPathComponent(Paths.hash(seriesID), isDirectory: true)
    }
    nonisolated func downloadDir(seriesID: String, chapter: String) -> URL {
        downloadDir(seriesID: seriesID).appendingPathComponent(Paths.hash(chapter), isDirectory: true)
    }

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
        let refs = try await src.pages(c, of: s)
        let remote = refs.compactMap { r -> String? in if case .remote(let u) = r { u.absoluteString } else { nil } }
        if remote.count == refs.count { update(s.id, c.url) { st, _ in st.pageURLs = remote; st.pagesFetched = Date(); st.pageCount = remote.count } }
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
        guard pageAspects(id, chapter: url) != a else { return }
        update(id, url) { st, _ in st.pageAspects = a }
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
        e.categoryIDs = ids.isEmpty ? nil : ids
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
            e.isSaved && (category == nil || e.categoryIDs?.contains(category!) == true)
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

    // MARK: storage

    public struct StorageUsage: Sendable {
        public var downloads: Int64
        public var cache: Int64
        public init(downloads: Int64, cache: Int64) { self.downloads = downloads; self.cache = cache }
    }

    public func storageUsage() -> StorageUsage {
        StorageUsage(downloads: Self.size(of: Paths.downloads), cache: Self.size(of: Paths.cache) + ExtensionEngine.cacheSize())
    }

    public nonisolated static func size(of dir: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    public func clearCache() {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: Paths.cache, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: u) }
        ExtensionEngine.clearEngineCaches(includingNetwork: ExtensionEngine.shared.state != .running)
        DiskCache.shared.clear()
    }

    public func clearAllDownloads() {
        cancelDownloads()
        for e in entries { try? FileManager.default.removeItem(at: downloadDir(seriesID: e.id)) }
        for i in entries.indices { for j in entries[i].chapters.indices { entries[i].chapters[j].downloaded = false } }
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

    private let file: URL
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
