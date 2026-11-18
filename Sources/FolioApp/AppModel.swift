import AppKit
import FolioCore
import ImageIO
import SwiftUI

struct WebTarget: Identifiable { let url: URL; let title: String; var id: URL { url } }

enum SidebarItem: Hashable {
    case search, library, recents, sources, extensions, source(String), settings
}

@MainActor
final class AppModel: ObservableObject {
    let library = Library()
    let extensions = ExtensionsModel()
    let search = GlobalSearchModel()

    init() {
        extensions.app = self
        library.onDownloadError = { [weak self] m in self?.error = m }
        applyAppearance()
        library.pruneReadDownloads()
        autoUpdateOnLaunch()
        autoBackupOnLaunch()
        ExtensionEngine.shared.flareSolverrURL = library.settings.flareSolverrURL
        // Bring installed extensions online in the background.
        // Only if the engine is already on disk: a missing one is downloaded when the user first needs it, never at launch.
        if !library.settings.extensionSources.isEmpty && ExtensionEngine.shared.isInstalled {
            Task { [weak self] in
                guard let self else { return }
                do { try await ExtensionEngine.shared.ensureRunning(); try await self.library.syncExtensionSources() }
                catch { self.report(error) }
            }
        }
    }
    @Published var sidebar: SidebarItem? = .library
    /// Bumped to put the cursor in the library's search field (⌘K).
    @Published var searchFocus = 0
    @Published var debugFilterPanel = false      // dev only: lets the QA harness open the filter panel
    /// A page open in the in-app web view (a source's own site for a series or chapter).
    @Published var web: WebTarget?
    /// The library series being moved to another source (shows the migrate sheet).
    @Published var migrating: LibraryEntry?
    func openWeb(_ urlString: String?, title: String) {
        guard let u = urlString.flatMap(URL.init(string:)), u.scheme?.hasPrefix("http") == true else { status = "This source didn’t give a web address."; return }
        web = WebTarget(url: u, title: title)
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
        guard s.autoBackup, !library.entries.isEmpty,
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
        let r = await library.refreshAll(onlyRulesApply: true)
        updating = false
        library.settings.lastAutoUpdate = Date()
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
        var n = 0
        for u in p.urls {
            do { _ = try library.local.importItem(u); n += 1 } catch { report(error) }
        }
        status = "Imported \(n) item\(n == 1 ? "" : "s") into Local files."
        sidebar = .source("local")
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
        setReaderChrome(false)
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
                Task { await FetchScheduler.shared.promote(key: key, to: priority) }
            }
        } else {
            let e = Load(priority)
            e.task = Task { [weak self, weak e] in
                let d = try? await FetchPriority.$current.withValue(priority) { try await load() }
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
