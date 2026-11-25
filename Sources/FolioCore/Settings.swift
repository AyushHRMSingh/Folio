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

/// A series you never want to see again. Hidden by id and by title (so it stays hidden on every source).
public struct BlacklistedSeries: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sourceID: String
    public var added: Date
    public init(_ s: Series, added: Date = Date()) { id = s.id; title = s.title; sourceID = s.sourceID; self.added = added }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? UUID().uuidString
        title = c.lenient(String.self, .title) ?? ""
        sourceID = c.lenient(String.self, .sourceID) ?? ""
        added = c.lenient(Date.self, .added) ?? Date()
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
            && (!completed || e.series.status.isFinished)
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
    /// Series hidden everywhere: Browse, search results, library, history.
    public var blacklist: [BlacklistedSeries] = []
    /// When the user accepted the extensions notice (responsibility for content they add). nil = not yet.
    public var extensionsNoticeAccepted: Date? = nil
    public var pageNumberReset = true             // one-time migration flag: page counter went off by default
    public var seamlessChapters = true            // webtoon: continue straight into the next chapter
    public var doublePage = false                 // paged: two pages side by side, like a book
    public var doubleFirstAlone = true            // the first page is a cover and stands alone
    public var splitWidePages = false             // single-page: a wide spread is shown as two halves
    public var cropBorders = false                // paged: zoom away plain white/black page margins
    public var autoBackup = false                 // a dated backup each day Folio opens; asked in first-launch setup
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
    /// PIN / Touch ID lock. Nil = off.
    public var appLock: AppLock?
    /// Folio's windows go black while another app is in front (app switcher, Mission Control, beside other apps).
    public var privacyScreen = true
    /// First-launch setup (extensions, backup, reading style, page width) has been seen.
    public var setupDone = false
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
        blacklist = (c.lenient([Lossy<BlacklistedSeries>].self, .blacklist) ?? []).compactMap(\.value)
        extensionsNoticeAccepted = c.lenient(Date.self, .extensionsNoticeAccepted)
        seamlessChapters = c.lenient(Bool.self, .seamlessChapters) ?? true
        doublePage = c.lenient(Bool.self, .doublePage) ?? false
        doubleFirstAlone = c.lenient(Bool.self, .doubleFirstAlone) ?? true
        splitWidePages = c.lenient(Bool.self, .splitWidePages) ?? false
        cropBorders = c.lenient(Bool.self, .cropBorders) ?? false
        autoBackup = c.lenient(Bool.self, .autoBackup) ?? false
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
        appLock = c.lenient(AppLock.self, .appLock)
        privacyScreen = c.lenient(Bool.self, .privacyScreen) ?? true
        setupDone = c.lenient(Bool.self, .setupDone) ?? false
        appearance = c.lenient(AppearanceMode.self, .appearance) ?? .system
        flareSolverrURL = c.lenient(String.self, .flareSolverrURL) ?? ""
    }
}

/// One comic's own reading settings. Every nil field follows the library default.
public struct ReaderOverrides: Codable, Hashable, Sendable {
    public var webtoonWidth: Double?
    public var pageGap: Double?
    public var readerBackground: ReaderBackground?
    public var autoScrollSpeed: Double?
    public var seamlessChapters: Bool?
    public var tapZones: TapZones?
    public var invertTapZones: Bool?
    public var doublePage: Bool?
    public var doubleFirstAlone: Bool?
    public var splitWidePages: Bool?
    public var cropBorders: Bool?
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        webtoonWidth = c.lenient(Double.self, .webtoonWidth); pageGap = c.lenient(Double.self, .pageGap)
        readerBackground = c.lenient(ReaderBackground.self, .readerBackground)
        autoScrollSpeed = c.lenient(Double.self, .autoScrollSpeed); seamlessChapters = c.lenient(Bool.self, .seamlessChapters)
        tapZones = c.lenient(TapZones.self, .tapZones); invertTapZones = c.lenient(Bool.self, .invertTapZones)
        doublePage = c.lenient(Bool.self, .doublePage); doubleFirstAlone = c.lenient(Bool.self, .doubleFirstAlone)
        splitWidePages = c.lenient(Bool.self, .splitWidePages); cropBorders = c.lenient(Bool.self, .cropBorders)
    }
    public var isEmpty: Bool { self == ReaderOverrides() }
}

/// The reading settings in effect for one comic (its own choices over the defaults).
public struct ReaderPrefs: Equatable, Sendable {
    public var mode: ReadingMode
    public var webtoonWidth: Double
    public var pageGap: Double
    public var readerBackground: ReaderBackground
    public var autoScrollSpeed: Double
    public var seamlessChapters: Bool
    public var tapZones: TapZones
    public var invertTapZones: Bool
    public var doublePage: Bool
    public var doubleFirstAlone: Bool
    public var splitWidePages: Bool
    public var cropBorders: Bool
}

