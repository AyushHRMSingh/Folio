import AppKit
import Combine
import FolioCore
import SwiftUI

// MARK: - Model

struct ReaderItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case divider(Chapter)                        // slim chapter-name line between chapters
        case page(Chapter, PageRef, Int, Int)        // chapter, page, index, count
        case transition(Chapter, Chapter?)           // finished X, next Y
    }
    let id: String
    let kind: Kind
}

struct ScrollCommand: Equatable {
    enum Kind: Equatable { case toItem(String, animated: Bool), byViewport(CGFloat), byPoints(CGFloat), zoomBy(CGFloat), zoomTo(CGFloat) }
    let id = UUID()
    let kind: Kind
}

enum ReaderPopover { case chapters, settings }

/// Where you are in the chapter, as a fractional page (3.5 = halfway down page 4). Kept apart from
/// ReaderModel so that scrolling only redraws the scrubber, never the whole reader.
@MainActor
final class ScrubState: ObservableObject {
    @Published var position: Double = 0
    var dragging = false
}

@MainActor
final class ReaderModel: ObservableObject {
    let app: AppModel
    let series: Series
    var library: Library { app.library }

    @Published var chapter: Chapter
    @Published var pages: [PageRef] = []          // pages of the current chapter
    @Published var index = 0 { didSet { if mode != .webtoon { scrub.position = Double(index) }; if oldValue != index { half = 0 } } }
    /// Which half of a wide page is showing (split-wide-pages): 0 = first read, 1 = second.
    @Published var half = 0   // page within the current chapter
    let scrub = ScrubState()
    /// Set by the webtoon canvas: jump to a fractional page position without going through SwiftUI.
    var scrubHandler: ((Double) -> Void)?
    @Published var items: [ReaderItem] = []       // webtoon stream (may span several chapters)
    @Published var loading = true
    @Published var error: String?
    @Published var mode: ReadingMode
    /// This comic's reading settings (its own choices over the defaults). Kept current as either changes.
    @Published private(set) var prefs: ReaderPrefs
    private var prefsWatch: AnyCancellable?
    @Published var controls = false
    @Published var autoScroll = false
    @Published var toast: String?
    @Published var popover: ReaderPopover? { didSet { if popover == nil { scheduleHide() } else { controls = true } } }
    @Published var command: ScrollCommand?
    @Published var appendingNext = false
    /// Magnification of the pages. Independent of the width/margin setting; not saved.
    @Published var zoom: CGFloat = 1
    var hoveringBars = false { didSet { if !hoveringBars { scheduleHide() } } }
    private(set) var source: Source?

    private var pagesByChapter: [String: [PageRef]] = [:]
    private var stream: [Chapter] = []
    private var hideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var chapterPrefetch: [String: Task<Void, Never>] = [:]
    private var activity: NSObjectProtocol?

    init(app: AppModel, series: Series, chapter: Chapter) {
        self.app = app; self.series = series; self.chapter = chapter
        self.mode = app.library.mode(for: series.id)
        self.prefs = app.library.readerPrefs(for: series.id)
        let lib = app.library, id = series.id
        prefsWatch = lib.$settings.map { _ in () }.merge(with: lib.$entries.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                let p = lib.readerPrefs(for: id)
                if p != self.prefs { self.prefs = p }
            }
        if app.library.settings.keepAwake {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Reading")
        }
        Task { await open(chapter, page: nil) }
    }

    var state: ChapterState? { library.entry(series.id)?.chapters.first { $0.chapter.url == chapter.url } }
    var nextChapter: Chapter? { library.next(after: chapter.url, in: series.id, skipRead: library.settings.skipReadChapters) }
    var previousChapter: Chapter? { library.previous(before: chapter.url, in: series.id, skipRead: library.settings.skipReadChapters) }

    static func pageID(_ c: Chapter, _ i: Int) -> String { "p|\(c.url)|\(i)" }

    // MARK: loading

    private func loadPages(_ c: Chapter) async throws -> [PageRef] {
        if let p = pagesByChapter[c.url] { return p }
        let (src, p) = try await library.pages(series, c)
        source = src
        pagesByChapter[c.url] = p
        if let a = library.pageAspects(series.id, chapter: c.url), a.count == p.count {     // remembered from last time
            for (i, ref) in p.enumerated() { Images.shared.seed(Images.key(ref), CGFloat(a[i])) }
        }
        return p
    }

    /// Counts opens; a load that finishes after a newer one started is dropped (slow sources return out of order).
    private var openGeneration = 0
    /// False from opening a chapter until the canvas first reports the requested page on screen. Neighbouring
    /// chapters are only attached after that, so they can never shift the view before it has settled.
    private var settled = false
    /// The chapter a next/previous jump is heading to. Chapters scrolled through on the way are not "read".
    private var jumpTarget: String?

    func open(_ c: Chapter, page: Int?, atEnd: Bool = false) async {
        openGeneration += 1
        let generation = openGeneration
        loading = true
        error = nil
        autoScroll = false
        settled = false
        jumpTarget = nil
        do {
            let p = try await loadPages(c)
            guard generation == openGeneration else { return }
            chapter = c
            pages = p
            let st = state
            let resume = (st?.read == false) ? (st?.lastPage ?? 0) : 0
            index = max(0, min(page ?? (atEnd ? p.count - 1 : resume), p.count - 1))
            for (u, t) in chapterPrefetch where u != c.url { t.cancel(); chapterPrefetch[u] = nil }
            stream = [c]
            entered = [c.url]
            rebuild()
            loading = false
            if mode == .webtoon { command = ScrollCommand(kind: .toItem(Self.pageID(c, index), animated: false)) }
            saveProgress()
            preload(from: index)
            show(toast: c.name)
            Task { [weak self] in         // fallback: never withhold neighbours forever if the first report is missed
                try? await Task.sleep(for: .seconds(1.5))
                if self?.openGeneration == generation { self?.settled = true }
            }
        } catch {
            guard generation == openGeneration else { return }
            loading = false
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func rebuild() {
        var out: [ReaderItem] = []
        for c in stream {
            let ps = pagesByChapter[c.url] ?? []
            if c != stream.first { out.append(ReaderItem(id: "d|\(c.url)", kind: .divider(c))) }
            for (i, p) in ps.enumerated() { out.append(ReaderItem(id: Self.pageID(c, i), kind: .page(c, p, i, ps.count))) }
            // An end card only where the strip really ends (last chapter, or continuous scrolling is off).
            let next = library.next(after: c.url, in: series.id)
            if c == stream.last, next == nil || !prefs.seamlessChapters {
                out.append(ReaderItem(id: "t|\(c.url)", kind: .transition(c, next)))
            }
        }
        items = out
    }

    /// Webtoon: quietly append the next chapter so reading never stops.
    private var attachTail: Task<Void, Never>?
    private var attachQueued: Set<String> = []
    /// Neighbour chapters attach strictly one after the other, each as a plain append or prepend.
    private func attach(_ kind: String, _ op: @escaping @MainActor () async -> Void) {
        guard attachQueued.insert(kind).inserted else { return }
        let prev = attachTail
        attachTail = Task { [weak self] in
            await prev?.value
            await op()
            self?.attachQueued.remove(kind)
        }
    }

    func appendNextIfNeeded() async {
        guard mode == .webtoon, prefs.seamlessChapters, !appendingNext,
              let last = stream.last, let n = library.next(after: last.url, in: series.id) else { return }
        appendingNext = true
        defer { appendingNext = false }
        do {
            _ = try await loadPages(n)
            guard stream.last == last else { return }
            stream.append(n)
            rebuild()
            prefetchEdge(n, first: true)
        } catch { app.report(error) }
    }

    /// Webtoon: quietly attach the previous chapter above; the canvas compensates the scroll offset.
    func prependPreviousIfNeeded() async {
        guard mode == .webtoon, prefs.seamlessChapters, !prependingPrev,
              let first = stream.first, let p = library.previous(before: first.url, in: series.id) else { return }
        prependingPrev = true
        defer { prependingPrev = false }
        do {
            _ = try await loadPages(p)
            guard stream.first == first else { return }
            stream.insert(p, at: 0)
            rebuild()
            prefetchEdge(p, first: false)
        } catch { app.report(error) }
    }
    private var prependingPrev = false

    /// Chapters whose pages may all load: the one you opened and any you've scrolled into.
    /// A freshly attached neighbour loads only its two pages nearest you.
    private var entered: Set<String> = []
    func mayLoad(_ c: Chapter, index i: Int, count: Int) -> Bool {
        if entered.contains(c.url) || c.url == chapter.url { return true }
        guard let k = stream.firstIndex(of: c), let cur = stream.firstIndex(of: chapter) else { return true }
        return k > cur ? i < 2 : i >= count - 2
    }
    /// Set by the canvas: re-check which tiles may start loading.
    var refreshHandler: (() -> Void)?

    private func prefetchEdge(_ c: Chapter, first: Bool) {
        guard let source, let ps = pagesByChapter[c.url] else { return }
        for p in (first ? Array(ps.prefix(2)) : Array(ps.suffix(2))) {
            Task { await Images.shared.prefetch(p, source: source) }
        }
    }

    /// Called by the webtoon viewer with the ids currently on screen.
    func visible(_ ids: [String]) {
        let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        let shown = ids.compactMap { order[$0] }.sorted().map { items[$0] }
        // The strip's end card on screen: that chapter is finished.
        for it in shown { if case .transition(let c, _) = it.kind, let n = pagesByChapter[c.url]?.count, n > 0 {
            library.setProgress(series.id, chapter: c.url, page: n - 1, of: n)
        } }
        guard let top = shown.first(where: { if case .page = $0.kind { true } else { false } }),
              case .page(let c, _, let i, _) = top.kind else {
            if shown.contains(where: { if case .transition = $0.kind { true } else { false } }) { attach("next") { [weak self] in await self?.appendNextIfNeeded() } }
            return
        }
        if !settled, shown.contains(where: { $0.id == Self.pageID(chapter, index) }) { settled = true }
        if c.url != chapter.url {
            // Crossing forward out of a chapter by reading finishes it. A next/previous jump doesn't: the
            // chapters it flies over were not read. Crossing back never un-reads anything.
            if jumpTarget == nil, let a = stream.firstIndex(of: chapter), let b = stream.firstIndex(of: c), b > a,
               let n = pagesByChapter[chapter.url]?.count, n > 0 {
                library.setProgress(series.id, chapter: chapter.url, page: n - 1, of: n)
            }
            chapter = c
            pages = pagesByChapter[c.url] ?? []
            entered.insert(c.url)
            show(toast: c.name)
            refreshHandler?()
            if c.url == jumpTarget { jumpTarget = nil }
        }
        if i != index { index = i; saveProgress() }
        if settled {
            if let last = stream.last, c.url == last.url, i >= pages.count - 6 { attach("next") { [weak self] in await self?.appendNextIfNeeded() } }
            if let first = stream.first, c.url == first.url, i <= 5 { attach("prev") { [weak self] in await self?.prependPreviousIfNeeded() } }
        }
        preload(from: i)
    }

    func preload(from i: Int) {
        guard let source else { return }
        prefetchChapter(chapter, around: i)
        let ahead = mode == .webtoon ? max(8, library.settings.preloadPages * 2) : library.settings.preloadPages
        let upcoming: [PageRef]
        if mode == .webtoon, let start = items.firstIndex(where: { $0.id == Self.pageID(chapter, i) }) {
            upcoming = items[(start + 1)...].prefix(ahead + 3).compactMap {
                if case .page(let pc, let p, let k, let n) = $0.kind, mayLoad(pc, index: k, count: n) { p } else { nil }
            }
        } else {
            upcoming = pages.indices.filter { $0 > i && $0 <= i + ahead }.map { pages[$0] }
        }
        // Read-ahead runs at low priority, nearest page first; pages that are no longer ahead are cancelled.
        let wanted = Dictionary(upcoming.map { (Images.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (k, t) in prefetching where wanted[k] == nil { t.cancel(); prefetching[k] = nil }
        for p in upcoming where prefetching[Images.key(p)] == nil && Images.shared.cached(Images.key(p)) == nil {
            let k = Images.key(p)
            prefetching[k] = Task { [weak self] in
                _ = await Images.shared.page(p, source: source, priority: .low)
                self?.prefetching[k] = nil
            }
        }
    }
    private var prefetching: [String: Task<Void, Never>] = [:]

    /// Starts fetching every page of a chapter straight away — nearest to where you are first, then the
    /// rest — into the disk cache. It runs behind anything you're actually looking at and stops when you leave.
    func prefetchChapter(_ c: Chapter, around i: Int) {
        guard let source, let ps = pagesByChapter[c.url], chapterPrefetch[c.url] == nil else { return }
        let order = Array(i..<ps.count) + Array((0..<i).reversed())
        chapterPrefetch[c.url] = Task { [weak self] in
            await withTaskGroup(of: Void.self) { g in
                for k in order { g.addTask { await Images.shared.prefetch(ps[k], source: source) } }
            }
            if !Task.isCancelled { self?.saveAspects(c) }
        }
    }

    /// Remember every page's shape for this chapter (only once all are known).
    func saveAspects(_ c: Chapter) {
        guard let ps = pagesByChapter[c.url] else { return }
        let a = ps.compactMap { Images.shared.aspect(Images.key($0)) }
        guard a.count == ps.count else { return }
        library.setPageAspects(series.id, chapter: c.url, a.map { Float($0) })
    }

    func saveProgress() {
        guard !pages.isEmpty else { return }
        library.setProgress(series.id, chapter: chapter.url, page: index, of: pages.count)
    }

    // MARK: navigation

    func setIndex(_ i: Int) {
        guard !pages.isEmpty else { return }
        let n = max(0, min(i, pages.count - 1))
        index = n
        if mode == .webtoon { command = ScrollCommand(kind: .toItem(Self.pageID(chapter, n), animated: false)) }
        saveProgress()
        preload(from: n)
    }

    // MARK: spreads and split pages (paged modes)

    var doubleOn: Bool { mode != .webtoon && prefs.doublePage }
    var splitting: Bool { mode != .webtoon && !doubleOn && prefs.splitWidePages }

    func isWide(_ i: Int) -> Bool {
        guard pages.indices.contains(i), let a = Images.shared.aspect(Images.key(pages[i])) else { return false }
        return Double(a) > PageSpreads.wideThreshold
    }

    var spreadLayout: [[Int]] {
        PageSpreads.layout(count: pages.count, isWide: { [self] in isWide($0) }, firstAlone: prefs.doubleFirstAlone)
    }

    /// Page indices on screen right now: one page, or two in double-page mode.
    var displayedPages: [Int] {
        guard doubleOn else { return [index] }
        let l = spreadLayout
        return l.isEmpty ? [index] : l[PageSpreads.spread(containing: index, in: l)]
    }

    func forward() {
        if splitting, isWide(index), half == 0 { half = 1; return }
        if doubleOn {
            let l = spreadLayout, k = PageSpreads.spread(containing: index, in: l)
            if k + 1 < l.count { setIndex(l[k + 1][0]) } else { goNext() }
            return
        }
        index < pages.count - 1 ? setIndex(index + 1) : goNext()
    }

    func back() {
        if splitting, isWide(index), half == 1 { half = 0; return }
        if doubleOn {
            let l = spreadLayout, k = PageSpreads.spread(containing: index, in: l)
            if k > 0 { setIndex(l[k - 1][0]) } else { goPrevious(atEnd: true) }
            return
        }
        if index > 0 {
            setIndex(index - 1)
            if splitting, isWide(index) { half = 1 }       // arrive on the half you'd read last
        } else { goPrevious(atEnd: true) }
    }

    private func beginJump(to c: Chapter) {
        jumpTarget = c.url
        let target = c.url
        Task { [weak self] in         // safety net: never leave the guard on if the jump is interrupted
            try? await Task.sleep(for: .seconds(2.5))
            if self?.jumpTarget == target { self?.jumpTarget = nil }
        }
    }

    func goNext() {
        guard let n = nextChapter else { show(toast: "You're all caught up"); return }
        if mode == .webtoon, stream.contains(n) {
            beginJump(to: n)
            command = ScrollCommand(kind: .toItem(Self.pageID(n, 0), animated: true))
        } else {
            Task { await open(n, page: 0) }
        }
    }

    func goPrevious(atEnd: Bool = false) {
        guard let p = previousChapter else { return }
        if mode == .webtoon, stream.contains(p) {
            beginJump(to: p)
            command = ScrollCommand(kind: .toItem(Self.pageID(p, 0), animated: true))
        } else {
            Task { await open(p, page: atEnd ? nil : 0, atEnd: atEnd) }
        }
    }

    func jump(to c: Chapter) {
        popover = nil
        Task { await open(c, page: nil) }
    }

    func scroll(_ k: ScrollCommand.Kind) { command = ScrollCommand(kind: k) }

    func setMode(_ m: ReadingMode) {
        guard m != mode else { return }
        mode = m
        library.setMode(series.id, m)
        autoScroll = false
        if m == .webtoon {
            stream = [chapter]; rebuild()
            command = ScrollCommand(kind: .toItem(Self.pageID(chapter, index), animated: false))
        }
        show(toast: m.label)
    }

    // MARK: chrome

    /// The overlay only changes on a click (or when something needs it): no idle timer, no waking on mouse movement.
    func poke() {
        if !controls { withAnimation(.easeOut(duration: 0.18)) { controls = true } }
    }

    func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controls.toggle() }
        if controls { scheduleHide() }
    }

    /// Controls fade after ~2s without intent; the cursor goes with them.
    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.hoveringBars, self.popover == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.controls = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private var mouseMonitor: Any?
    /// Mouse into the top/bottom 80pt summons the controls. Scrolling never does.
    func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let w = e.window, let h = w.contentView?.bounds.height else { return e }
                let y = e.locationInWindow.y
                if (y > h - 80 || y < 80) && !self.controls && !self.loading {
                    withAnimation(.easeOut(duration: 0.18)) { self.controls = true }
                    self.scheduleHide()
                } else if self.controls && !self.hoveringBars { self.scheduleHide() }
                return e
            }
        }
        app.window?.acceptsMouseMovedEvents = true
    }

    func show(toast t: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = t }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.toast = nil }
        }
    }

    /// The chapter's own page on the source's website (or the series page when the source gives none), in Folio Web.
    func openInWeb(_ c: Chapter? = nil) {
        let ch = c ?? chapter
        guard let u = ch.webURL ?? series.webURL else { show(toast: "This source didn\u{2019}t give a web address"); return }
        autoScroll = false
        app.openWeb(u, title: "\(series.title) · \(ch.name)")
    }

    var bookmarked: Bool { state?.bookmarked ?? false }
    func toggleBookmark() {
        library.setBookmarked(series.id, chapter: chapter.url, !bookmarked)
        show(toast: bookmarked ? "Bookmarked" : "Bookmark removed")
        objectWillChange.send()
    }

    /// Called by the canvas whenever its viewport magnification changes.
    func zoomChanged(_ m: CGFloat, toast: Bool) {
        guard abs(m - zoom) > 0.001 else { return }
        zoom = m
        if toast { show(toast: m <= 1.001 ? "Zoom reset" : "Zoom \(Int((m * 100).rounded()))%") }
    }
    func zoomIn() { command = ScrollCommand(kind: .zoomBy(1.25)) }
    func zoomOut() { command = ScrollCommand(kind: .zoomBy(0.8)) }
    func resetZoom() { command = ScrollCommand(kind: .zoomTo(1)) }

    func toggleAutoScroll() {
        guard mode == .webtoon else { return }
        autoScroll.toggle()
        show(toast: autoScroll ? "Auto-scroll on" : "Auto-scroll off")
    }

    /// Forget what we remembered about this chapter and ask the source again.
    func retry() {
        library.forgetPages(series.id, chapter: chapter.url)
        pagesByChapter[chapter.url] = nil
        chapterPrefetch[chapter.url]?.cancel(); chapterPrefetch[chapter.url] = nil
        Task { await open(chapter, page: index) }
    }

    func close(animated: Bool = true) {
        saveProgress()
        autoScroll = false
        saveAspects(chapter)
        chapterPrefetch.values.forEach { $0.cancel() }; chapterPrefetch = [:]
        prefetching.values.forEach { $0.cancel() }; prefetching = [:]
        hideTask?.cancel()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        NSCursor.unhide()
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if animated { app.closeReader() }
    }
}
