import AppKit
import FolioCore
import ImageIO
import SwiftUI

enum SidebarItem: Hashable {
    case search, library, recents, sources, extensions, source(String), settings, downloads
}

@MainActor
final class AppModel: ObservableObject {
    let library = Library()
    let extensions = ExtensionsModel()
    let search = GlobalSearchModel()
    /// PIN / Touch ID lock (Settings › Privacy).
    let lock: LockModel
    /// Black cover while another app is in front (Settings › Privacy).
    let privacy: PrivacyScreen

    init() {
        lock = LockModel(library: library)
        privacy = PrivacyScreen(library: library)
        lock.app = self
        extensions.app = self
        library.onDownloadError = { [weak self] m in self?.error = m }
        applyAppearance()
        library.pruneReadDownloads()
        autoUpdateOnLaunch()
        autoBackupOnLaunch()
        configureCloudflare()
        CloudflareSolver.shared.context = { [weak self] in
            guard let r = self?.reader, let lib = self?.library else { return nil }
            let web = (r.series.webURL).flatMap(URL.init(string:))
            return (lib.source(r.series.sourceID)?.name ?? "This source", web.flatMap { URL(string: "\($0.scheme ?? "https")://\($0.host ?? "")/") })
        }
        CloudflareSolver.shared.onBlocked = { [weak self] m in self?.status = m }
        Task { [weak self] in
            // Folio's own Cloudflare helper (the user verifies in a small window) must be listening before the engine
            // starts, because the engine is told its address at launch.
            await CloudflareSolver.shared.start()
            guard let self else { return }
            self.configureCloudflare()
            // Bring installed extensions online in the background.
            // Only if the engine is already on disk: a missing one is downloaded when the user first needs it, never at launch.
            if !self.library.settings.extensionSources.isEmpty && ExtensionEngine.shared.isInstalled {
                do { try await ExtensionEngine.shared.ensureRunning(); try await self.library.syncExtensionSources() }
                catch { self.report(error) }
            }
        }
    }

    /// Cloudflare checks: an external FlareSolverr if the user set one, otherwise Folio's own helper, which shows
    /// the check to the user. Takes effect the next time the engine starts.
    func configureCloudflare() {
        let e = ExtensionEngine.shared
        let user = library.settings.flareSolverrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            e.flareSolverrURL = user; e.flareSolverrTimeoutSeconds = 60; e.flareSolverrResponseFallback = true
        } else if let u = CloudflareSolver.shared.url {
            e.flareSolverrURL = u; e.flareSolverrTimeoutSeconds = 240; e.flareSolverrResponseFallback = false
        } else {
            e.flareSolverrURL = ""
        }
    }
    @Published var sidebar: SidebarItem? = .library
    /// Bumped to put the cursor in the library's search field (⌘K).
    @Published var searchFocus = 0

    /// Searches every source (library, local, OPDS, extensions) for `q` and shows the results in the library page.
    func searchEverywhere(_ q: String) {
        closeReaderIfOpen()
        sidebar = .library
        path = NavigationPath()
        search.query = q
        search.run(q, library: library)
    }
    private func closeReaderIfOpen() { if reader != nil { reader?.close() } }
    @Published var debugFilterPanel = false      // dev only: lets the QA harness open the filter panel
    /// The library series being moved to another source (shows the migrate sheet).
    @Published var migrating: LibraryEntry?
    /// Folio's web view, shown as a page inside the main window, on top of whatever you were doing (the reader
    /// stays open underneath, so Back returns to the same spot). Nil when closed.
    @Published var web: WebState?
    /// The reader or the web view has the whole window (no sidebar, no toolbar).
    var fullPage: Bool { reader != nil || web != nil }

    /// The one entry point to Folio's in-app web view (persistent Folio-only website data).
    func openWeb(_ urlString: String?, title: String) {
        guard let u = urlString.flatMap(URL.init(string:)), u.scheme?.hasPrefix("http") == true else { status = "This source didn’t give a web address."; return }
        reader?.autoScroll = false
        if let web { web.load(u); return }
        let s = WebState()
        s.load(u)
        setReaderChrome(true)
        withAnimation(.easeInOut(duration: 0.18)) { web = s }
    }

    func closeWeb() {
        guard let s = web else { return }
        s.shutdown()
        withAnimation(.easeInOut(duration: 0.18)) { web = nil }
        if reader == nil { setReaderChrome(false) }
    }
    @Published var error: String?
    @Published var status: String?
    @Published var updating = false

    func applyAppearance() {
        switch library.settings.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// One dated backup per day, kept to the last few.
    private func autoBackupOnLaunch() {
        let s = library.settings
        guard s.setupDone, s.autoBackup, !library.entries.isEmpty,
              s.lastAutoBackup.map({ !Calendar.current.isDateInToday($0) }) ?? true else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))       // after the launch work has settled
            guard let self else { return }
            if self.library.writeAutoBackup(keep: self.library.settings.backupsKept) != nil { self.library.settings.lastAutoBackup = Date() }
        }
    }

    /// Checks for new chapters on the schedule: once at start-up if due, then every ten minutes while open.
    private func autoUpdateOnLaunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.runScheduledUpdate(atLaunch: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await self?.runScheduledUpdate(atLaunch: false)
            }
        }
    }

    private func runScheduledUpdate(atLaunch: Bool) async {
        guard library.updateDue(atLaunch: atLaunch), !updating, !library.updatable().isEmpty else { return }
        updating = true
        let r = await library.runScheduledRefresh()
        updating = false
        if r.new > 0 { status = "\(r.new) new chapter\(r.new == 1 ? "" : "s") in your library." }
    }

    /// A cancelled request means the screen that asked for it went away — not a failure worth showing.
    static func isCancellation(_ e: Error) -> Bool {
        e is CancellationError || (e as? URLError)?.code == .cancelled || (e as NSError).code == NSURLErrorCancelled
    }

    func report(_ e: Error) {
        guard !Self.isCancellation(e) else { return }
        error = (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }

    func updateLibrary() {
        guard !updating else { return }
        updating = true
        Task {
            let r = await library.refreshAll()
            updating = false
            status = r.new == 0 ? "No new chapters." : "\(r.new) new chapter\(r.new == 1 ? "" : "s")."
            if !r.failed.isEmpty { error = "Couldn't update: " + r.failed.joined(separator: ", ") }
        }
    }

    func importLocal() {
        let p = NSOpenPanel()
        p.message = "Choose folders or .cbz/.zip files to copy into Folio's private library"
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.folder, .zip, .init(filenameExtension: "cbz") ?? .zip]
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        let local = library.local
        sidebar = .source("local")
        Task {
            var n = 0
            for (i, u) in urls.enumerated() {
                status = "Importing \(i + 1) of \(urls.count)…"
                let r = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                    Result { try local.importItem(u) }
                }.value
                switch r {
                case .success: n += 1
                case .failure(let e): report(e)
                }
            }
            status = "Imported \(n) item\(n == 1 ? "" : "s") into Local files."
            sidebar = .source("local")
        }
    }

    // MARK: reader (shown inside the main window)

    @Published var reader: ReaderModel?

    func read(_ series: Series, _ chapter: Chapter) {
        Task {
            do {
                if library.entry(series.id) == nil { try await library.track(series) }
                openReader(series, chapter)
            } catch { report(error) }
        }
    }

    /// Save to / remove from the library (long-press or right-click a cover).
    func toggleSaved(_ s: Series) async {
        do {
            if library.contains(s) { library.remove(s.id); status = "Removed from library." }
            else { try await library.add(s); status = "Saved to library." }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        } catch { report(error) }
    }

    func resume(_ entry: LibraryEntry) {
        guard let c = entry.resumeChapter?.chapter else { error = "No chapters yet."; return }
        openReader(entry.series, c)
    }

    weak var window: NSWindow?

    private func openReader(_ series: Series, _ chapter: Chapter) {
        reader?.close(animated: false)
        setReaderChrome(true)
        withAnimation(.easeInOut(duration: 0.22)) { reader = ReaderModel(app: self, series: series, chapter: chapter) }
    }

    func closeReader() {
        withAnimation(.easeInOut(duration: 0.22)) { reader = nil }
        library.pruneReadDownloads()
        if web == nil { setReaderChrome(false) }
    }

    @Published var path = NavigationPath()

    /// The reader takes the whole window. The toolbar itself is hidden declaratively (`.toolbar(.hidden)` in RootView);
    /// here we only make the title bar transparent and untitled — set once, never fought over with a timer.
    private func setReaderChrome(_ reading: Bool) {
        guard let w = window else { return }
        // The title bar stays transparent and untitled in both states (it is at launch); only the toolbar comes and goes.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.toolbar?.isVisible = !reading
    }
}

/// Shared image cache (memory only — nothing hits the disk outside Folio's data folder).
/// Images are decoded off the main thread and downsampled to display size, so long webtoon
/// strips scroll smoothly and memory stays bounded.
@MainActor
final class Images {
    static let shared = Images()
    private let cache = NSCache<NSString, NSImage>()
    init() {
        cache.countLimit = 2000
        cache.totalCostLimit = 900 * 1024 * 1024
    }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// Why the last load of `key` failed, in words a reader understands (nil = no failure recorded).
    private(set) var failures: [String: String] = [:]
    func failure(_ key: String) -> String? { failures[key] }

    static func reason(_ e: Error) -> String {
        if e is CloudflareError || (CloudflareSolver.recentlyBlocked && CloudflareError.matches("\(e)")) {
            return CloudflareSolver.recentlyBlocked ? "The image server is blocking Folio. Try another source for this series." : "Cloudflare check needed. Click to verify."
        }
        if let p = e as? PausedError { return p.errorDescription ?? "Paused." }
        if e is RateLimitedError { return "The site says Folio is asking too often. Folio paused this source for a while." }
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "No internet connection. Click to retry."
            case .timedOut: return "The site took too long. Click to retry."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "Can\u{2019}t reach the site. Click to retry."
            default: break
            }
        }
        let m = (e as? LocalizedError)?.errorDescription ?? "\(e)"
        if let r = m.range(of: #"HTTP \d{3}"#, options: .regularExpression) { return "The site returned an error (\(m[r])). Click to retry." }
        return "Couldn\u{2019}t load this page. Click to retry."
    }
    /// width / height of pages we've decoded before (kept even if the image is evicted).
    private var aspects: [String: CGFloat] = [:]
    func aspect(_ key: String) -> CGFloat? { aspects[key] }
    /// Called when a page's real shape becomes known before it is shown (read-ahead), so the layout can settle early.
    var onAspect: ((String) -> Void)?
    /// Shapes remembered from an earlier read: known before anything loads.
    func seed(_ key: String, _ a: CGFloat) { if aspects[key] == nil, a > 0 { aspects[key] = a } }

    /// Read-ahead: fetch the bytes into the disk cache (no decoding, so memory stays flat) and learn
    /// the page's real shape from its header. Lowest priority; cancelled with the task.
    func prefetch(_ p: PageRef, source: Source) async {
        let key = Self.key(p)
        guard cache.object(forKey: key as NSString) == nil else { return }
        let a: CGFloat? = await Task.detached(priority: .utility) { () -> CGFloat? in
            if case .file(let u) = p { return Images.aspect(of: CGImageSourceCreateWithURL(u as CFURL, nil)) }
            return nil
        }.value
        if let a { note(key, a); return }
        let data: Data? = await FetchPriority.$current.withValue(.low) { try? await source.imageData(p) }
        guard let data, !Task.isCancelled else { return }
        let a2: CGFloat? = await Task.detached(priority: .utility) { Images.aspect(of: CGImageSourceCreateWithData(data as CFData, nil)) }.value
        if let a2 { note(key, a2) }
    }
    private func note(_ key: String, _ a: CGFloat) {
        guard aspects[key] == nil else { return }
        aspects[key] = a
        onAspect?(key)
    }
    nonisolated static func aspect(of src: CGImageSource?) -> CGFloat? {
        guard let src, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }

    /// One in-flight load, shared by everyone who wants the same image. When the last interested
    /// caller goes away (view scrolled off, read-ahead no longer needed) the load is cancelled.
    private final class Load {
        var task: Task<NSImage?, Never>!
        var waiters = 0
        var priority: FetchPriority
        init(_ p: FetchPriority) { priority = p }
    }
    private var inflight: [String: Load] = [:]

    func image(_ key: String, maxWidth: CGFloat = 2000, priority: FetchPriority = .high,
               load: @escaping @Sendable () async throws -> Data?) async -> NSImage? {
        if let i = cache.object(forKey: key as NSString) { return i }
        if Task.isCancelled { return nil }
        let l: Load
        if let e = inflight[key] {
            l = e
            if priority > e.priority {                 // e.g. a read-ahead page just scrolled into view
                e.priority = priority
                ImageFetch.promote(alias: key, to: priority)      // the page URL is the image's alias in ImageFetch
            }
        } else {
            let e = Load(priority)
            e.task = Task { [weak self, weak e] in
                var d: Data?
                do {
                    // Dev only: FOLIO_DEBUG_FAIL makes every second page fail as a paused source would (to check the message).
                    if ProcessInfo.processInfo.environment["FOLIO_DEBUG_FAIL"] != nil, key.hasSuffix("2.png") || key.hasSuffix("2.jpg") {
                        throw PausedError(until: Date().addingTimeInterval(90))
                    }
                    d = try await FetchPriority.$current.withValue(priority) { try await load() }; self?.failures[key] = nil
                }
                catch { if !Task.isCancelled { self?.failures[key] = Images.reason(error) } }
                var img: NSImage?
                if let d, !Task.isCancelled {
                    img = await Task.detached(priority: .userInitiated) { Images.decode(d, maxWidth: maxWidth) }.value
                }
                if let self {
                    if let e, self.inflight[key] === e { self.inflight[key] = nil }
                    if let img {
                        if img.size.height > 0 { self.aspects[key] = img.size.width / img.size.height }
                        let px = img.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 1_000_000
                        self.cache.setObject(img, forKey: key as NSString, cost: px)
                    }
                }
                return img
            }
            inflight[key] = e
            l = e
        }
        l.waiters += 1
        return await withTaskCancellationHandler {
            await l.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                l.waiters -= 1
                if l.waiters <= 0 {
                    l.task.cancel()
                    if self?.inflight[key] === l { self?.inflight[key] = nil }
                }
            }
        }
    }

    nonisolated static func decode(_ d: Data, maxWidth: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0
        else { return NSImage(data: d) }
        let scale = min(1, maxWidth / w)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h) * scale,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return NSImage(data: d) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func coverKey(_ s: Series) -> String { "cover|" + s.id + "|" + (s.coverURL ?? "") }

    func cover(_ s: Series, source: Source?) async -> NSImage? {
        guard let source, s.coverURL != nil else { return nil }
        return await image(Self.coverKey(s), maxWidth: 600, priority: .normal) {
            if let c = s.coverURL, c.hasPrefix(Paths.covers.path) { return try Data(contentsOf: URL(fileURLWithPath: c)) }     // a cover picked from a page
            return try await source.coverData(s)
        }
    }

    static func key(_ p: PageRef) -> String {
        switch p { case .file(let u): u.path; case .remote(let u): u.absoluteString }
    }

    func page(_ p: PageRef, source: Source, priority: FetchPriority = .high) async -> NSImage? {
        let delay = DebugHook.delay
        return await image(Self.key(p), maxWidth: 2000, priority: priority) {
            if delay > 0 { try? await Task.sleep(for: .seconds(Double.random(in: 0.1...delay))) }
            return try await source.imageData(p)
        }
    }
}
