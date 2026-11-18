import AppKit
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
            out.append(ReaderItem(id: "d|\(c.url)", kind: .divider(c)))
            for (i, p) in ps.enumerated() { out.append(ReaderItem(id: Self.pageID(c, i), kind: .page(c, p, i, ps.count))) }
            // An end card only where the strip really ends (last chapter, or continuous scrolling is off).
            let next = library.next(after: c.url, in: series.id)
            if c == stream.last, next == nil || !library.settings.seamlessChapters {
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
        guard mode == .webtoon, library.settings.seamlessChapters, !appendingNext,
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
        guard mode == .webtoon, library.settings.seamlessChapters, !prependingPrev,
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

    var doubleOn: Bool { mode != .webtoon && library.settings.doublePage }
    var splitting: Bool { mode != .webtoon && !doubleOn && library.settings.splitWidePages }

    func isWide(_ i: Int) -> Bool {
        guard pages.indices.contains(i), let a = Images.shared.aspect(Images.key(pages[i])) else { return false }
        return Double(a) > PageSpreads.wideThreshold
    }

    var spreadLayout: [[Int]] {
        PageSpreads.layout(count: pages.count, isWide: { [self] in isWide($0) }, firstAlone: library.settings.doubleFirstAlone)
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
        withAnimation(.spring(response: 0.3)) { toast = t }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.toast = nil }
        }
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

// MARK: - View

extension ReaderBackground {
    var color: Color {
        switch self { case .black: .black; case .gray: Color(white: 0.16); case .white: Color(white: 0.97); case .auto: Theme.bg }
    }
    var ink: Color { self == .white ? .black : (self == .auto ? Theme.ink : .white) }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var library: Library
    @FocusState private var focused: Bool
    @State private var fullscreen = false

    init(model: ReaderModel) { self.model = model; self.library = model.app.library }

    var bg: ReaderBackground { library.settings.readerBackground }

    var body: some View {
        ZStack {
            bg.color.ignoresSafeArea()
            content
            if model.controls && !model.loading {
                VStack(spacing: 0) {
                    ReaderTopBar(model: model, library: library, fullscreen: fullscreen)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                    ReaderBottomBar(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if !model.controls && !model.loading && library.settings.showPageNumber && !model.pages.isEmpty {
                VStack { Spacer(); HStack { Spacer(); PageNumberPill(model: model) } }.allowsHitTesting(false)
            }
            if let t = model.toast {
                VStack {
                    Text(t).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 7)
                        .background(Color.black.opacity(0.88), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
                        .padding(.top, model.controls ? 70 : 22)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()      // the titlebar/menu bar sliding in and out must never push the controls around
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; model.installMouseMonitor() }
        .onChange(of: model.popover) { _, p in if p == nil { focused = true } }
        .onChange(of: model.controls) { _, _ in if model.popover == nil { focused = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullscreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullscreen = false }
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    @ViewBuilder var content: some View {
        if model.loading {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(bg.ink)
                Text(model.chapter.name).font(.callout).foregroundStyle(bg.ink.opacity(0.6))
            }
        } else if let e = model.error {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36))
                Text(e).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button("Back") { model.close() }.buttonStyle(.mono)
                    Button("Retry") { model.retry() }.buttonStyle(.monoPrimary)
                }
            }
            .foregroundStyle(bg.ink)
        } else if let source = model.source {
            let st = library.settings
            switch model.mode {
            case .webtoon:
                WebtoonStrip(model: model, source: source,
                             look: ReaderLook(widthFraction: st.webtoonWidth, gap: st.pageGap,
                                              background: st.readerBackground, autoScrollSpeed: st.autoScrollSpeed))
                    .ignoresSafeArea()
            case .leftToRight, .rightToLeft:
                PagedCanvas(model: model, source: source, background: st.readerBackground).ignoresSafeArea()
            }
        }
    }

    func handle(_ press: KeyPress) -> KeyPress.Result {
        let webtoon = model.mode == .webtoon
        let rtl = model.mode == .rightToLeft
        let shift = press.modifiers.contains(.shift)
        if press.modifiers.contains(.command) {
            switch press.characters {
            case "=", "+": model.zoomIn()
            case "-", "_": model.zoomOut()
            case "0": model.resetZoom()
            default: return .ignored
            }
            return .handled
        }
        switch press.key {
        case .escape:
            if model.popover != nil { model.popover = nil }
            else if fullscreen { NSApp.keyWindow?.toggleFullScreen(nil) }
            else { model.close() }
        case .downArrow: webtoon ? model.scroll(.byPoints(160)) : model.forward()
        case .upArrow: webtoon ? model.scroll(.byPoints(-160)) : model.back()
        case .space: webtoon ? model.scroll(.byViewport(shift ? -0.85 : 0.85)) : (shift ? model.back() : model.forward())
        case .pageDown: webtoon ? model.scroll(.byViewport(0.9)) : model.forward()
        case .pageUp: webtoon ? model.scroll(.byViewport(-0.9)) : model.back()
        case .rightArrow: webtoon ? model.scroll(.byViewport(0.85)) : (rtl ? model.back() : model.forward())
        case .leftArrow: webtoon ? model.scroll(.byViewport(-0.85)) : (rtl ? model.forward() : model.back())
        case .home: model.setIndex(0)
        case .end: model.setIndex(model.pages.count - 1)
        default:
            switch press.characters.lowercased() {
            case "j": webtoon ? model.scroll(.byPoints(160)) : model.forward()
            case "k": webtoon ? model.scroll(.byPoints(-160)) : model.back()
            case "]", "n": model.goNext()
            case "[", "p": model.goPrevious()
            case "a": model.toggleAutoScroll()
            case "m": model.toggleControls()
            case "f": NSApp.keyWindow?.toggleFullScreen(nil)
            case "b": model.toggleBookmark()
            case "c": model.popover = model.popover == .chapters ? nil : .chapters
            case "=", "+": model.zoomIn()
            case "-", "_": model.zoomOut()
            case "0": model.resetZoom()
            case "1": model.setMode(.webtoon)
            case "2": model.setMode(.rightToLeft)
            case "3": model.setMode(.leftToRight)
            default: return .ignored
            }
        }
        return .handled
    }
}

// MARK: - Webtoon pieces (hosted inside the native strip)

struct ChapterDivider: View {
    let chapter: Chapter
    let ink: Color
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(ink.opacity(0.14)).frame(height: 1)
            Text(chapter.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ink.opacity(0.5)).lineLimit(1).fixedSize()
            Rectangle().fill(ink.opacity(0.14)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TransitionCard: View {
    @ObservedObject var model: ReaderModel
    let from: Chapter
    let to: Chapter?
    let ink: Color

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 3) {
                Text("FINISHED").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(ink.opacity(0.5))
                Text(from.name).font(.headline).foregroundStyle(ink.opacity(0.85)).multilineTextAlignment(.center)
            }
            if let to {
                Image(systemName: "chevron.compact.down").font(.title2).foregroundStyle(ink.opacity(0.35))
                VStack(spacing: 3) {
                    Text("NEXT").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(ink.opacity(0.5))
                    Text(to.name).font(.title3.weight(.semibold)).foregroundStyle(ink).multilineTextAlignment(.center)
                }
                if model.appendingNext { ProgressView().controlSize(.small).tint(ink) }
                else if !model.app.library.settings.seamlessChapters || model.mode != .webtoon {
                    Button("Continue") { model.goNext() }.buttonStyle(.monoPrimary)
                }
            } else {
                Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(ink.opacity(0.8))
                Text("You're all caught up").font(.title3.weight(.semibold)).foregroundStyle(ink)
                Button("Back to \(model.series.title)") { model.close() }.buttonStyle(.mono)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ink.opacity(0.1)))
    }
}

// MARK: - Chrome

struct BarButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(active ? Color.black : Color.white)
                .background(active ? Color.white : Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ReaderTopBar: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var library: Library
    let fullscreen: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Where you are
            HStack(spacing: 12) {
                Button { model.close() } label: { Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.plain).help("Back (Esc)")
                Button { model.popover = .chapters } label: {
                    HStack(spacing: 8) {
                        Text(model.series.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(model.chapter.name).font(.system(size: 11.5, design: .monospaced)).opacity(0.6).lineLimit(1)
                    }
                }
                .buttonStyle(.plain).help("All chapters (C)")
                .popover(isPresented: Binding(get: { model.popover == .chapters }, set: { if !$0 { model.popover = nil } }), arrowEdge: .bottom) {
                    ChapterPicker(model: model, library: library)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            Spacer(minLength: 20)
            // Tools
            HStack(spacing: 16) {
                if model.mode == .webtoon {
                    Button { model.toggleAutoScroll() } label: { Image(systemName: model.autoScroll ? "pause.fill" : "play.fill").font(.system(size: 14)) }
                        .buttonStyle(.plain).help("Auto-scroll (A)")
                }
                Button { model.toggleBookmark() } label: { Image(systemName: model.bookmarked ? "bookmark.fill" : "bookmark").font(.system(size: 14)) }
                    .buttonStyle(.plain).help("Bookmark chapter (B)")
                Button { model.popover = .settings } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 14)) }
                    .buttonStyle(.plain).help("Reader settings")
                    .popover(isPresented: Binding(get: { model.popover == .settings }, set: { if !$0 { model.popover = nil } }), arrowEdge: .bottom) {
                        ReaderSettings(model: model, library: library)
                    }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
                }
                    .buttonStyle(.plain).help("Full screen (F)")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, fullscreen ? 12 : 44)       // below the window's own title bar (traffic lights), not sharing it
        .environment(\.colorScheme, .dark)
        .onHover { model.hoveringBars = $0 }
    }
}

/// Page scrubber: one notch per page, a thin thumb that tracks the scroll position continuously,
/// and dragging that moves the page under your finger rather than stepping.
struct PageScrubber: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var scrub: ScrubState
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let n = max(2, model.pages.count)
            let w = max(1, g.size.width)
            let rtl = model.mode == .rightToLeft
            let f = min(1, max(0, scrub.position / Double(n - 1)))
            let x = (rtl ? 1 - f : f) * w
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let step = size.width / CGFloat(n - 1)
                    let every = max(1, Int(ceil(5 / step)))                 // notches never closer than 5 pt
                    for k in stride(from: 0, to: n, by: every) {
                        let major = k % 10 == 0 || k == n - 1
                        let h: CGFloat = major ? 10 : 5
                        let kx = (rtl ? size.width - CGFloat(k) * step : CGFloat(k) * step)
                        let passed = Double(k) <= scrub.position + 0.001
                        ctx.fill(Path(CGRect(x: kx - 0.5, y: (size.height - h) / 2, width: 1, height: h)),
                                 with: .color(.white.opacity(passed ? 0.9 : 0.26)))
                    }
                }
                Capsule().fill(Color.white).frame(width: 3, height: 18).offset(x: x - 1.5)
                    .animation(model.mode == .webtoon ? nil : .easeOut(duration: 0.12), value: scrub.position)
                if dragging {
                    Text("\(Int(scrub.position.rounded()) + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.white, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.black).offset(x: min(max(0, x - 14), w - 28), y: -22)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true; scrub.dragging = true
                    var t = min(1, max(0, v.location.x / w)); if rtl { t = 1 - t }
                    if model.mode == .webtoon {
                        scrub.position = t * Double(n - 1)
                        model.scrubHandler?(scrub.position)
                    } else {
                        let i = Int((t * Double(n - 1)).rounded())
                        if i != model.index { model.setIndex(i) }
                    }
                }
                .onEnded { _ in dragging = false; scrub.dragging = false })
        }
        .frame(height: 24)
    }
}

struct ReaderBottomBar: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.goPrevious() } label: { Image(systemName: "backward.end").font(.system(size: 14)) }
                .buttonStyle(.plain).disabled(model.previousChapter == nil).opacity(model.previousChapter == nil ? 0.3 : 1).help("Previous chapter ([)")
            Text("\(model.index + 1)").font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(minWidth: 24, alignment: .trailing)
            if model.pages.count > 1 {
                PageScrubber(model: model, scrub: model.scrub)
            } else { Spacer() }
            Text("\(model.pages.count)").font(.system(size: 12, design: .monospaced)).opacity(0.5).frame(minWidth: 24, alignment: .leading)
            Button { model.goNext() } label: { Image(systemName: "forward.end").font(.system(size: 14)) }
                .buttonStyle(.plain).disabled(model.nextChapter == nil).opacity(model.nextChapter == nil ? 0.3 : 1).help("Next chapter (])")
            if abs(model.zoom - 1) > 0.01 {
                Button { model.resetZoom() } label: {
                    Text("\(Int((model.zoom * 100).rounded()))% ✕").font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.plain).help("Reset zoom (⌘0)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Color.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: 560)
        .padding(.horizontal, 24).padding(.bottom, 18)
        .environment(\.colorScheme, .dark)
        .onHover { model.hoveringBars = $0 }
    }
}

struct ChapterPicker: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var library: Library

    var body: some View {
        let chapters = (library.entry(model.series.id)?.ordered ?? []).reversed()
        ScrollViewReader { proxy in
            List(Array(chapters)) { c in
                Button { model.jump(to: c.chapter) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(c.read ? Color.clear : Theme.ink).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.chapter.name).fontWeight(c.chapter.url == model.chapter.url ? .bold : .regular)
                                .foregroundStyle(c.read && c.chapter.url != model.chapter.url ? .secondary : .primary)
                            if c.started { Text("Page \(c.lastPage + 1)\(c.pageCount.map { " of \($0)" } ?? "")").font(.caption).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        if c.bookmarked { Image(systemName: "bookmark.fill").foregroundStyle(Theme.ink) }
                        if c.downloaded { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary) }
                        if c.chapter.url == model.chapter.url { Image(systemName: "book.fill").foregroundStyle(Theme.ink) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(c.chapter.url)
            }
            .onAppear { proxy.scrollTo(model.chapter.url, anchor: .center) }
        }
        .frame(width: 340, height: 460)
    }
}

struct ReaderSettings: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var library: Library
    @State private var showShortcuts = false

    var body: some View {
        Group {
            if showShortcuts { shortcuts } else { panel }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .frame(width: 360)
        .frame(maxHeight: 560)
        .background(Theme.bg)
    }

    var panel: some View {
        ScrollView {
            VStack(spacing: 0) {
                SetRow(label: "Reading mode") {
                    MonoChoice(options: ReadingMode.allCases.map { ($0, $0.label) }, selection: Binding(get: { model.mode }, set: { model.setMode($0) }))
                }
                if library.settings.defaultMode != model.mode {
                    HStack { Spacer(); TextAction(title: "use for all series") { library.settings.defaultMode = model.mode } }.padding(.top, 6)
                }
                if model.mode == .webtoon {
                    SetRow(label: "Width") {
                        HStack(spacing: 10) {
                            Slider(value: $library.settings.webtoonWidth, in: 0.3...1).controlSize(.small).frame(width: 130)
                            Text("\(Int(library.settings.webtoonWidth * 100))%").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
                        }
                    }
                    SetRow(label: "Gap between pages") {
                        MonoChoice(options: [(0.0, "none"), (8.0, "small"), (24.0, "large")], selection: $library.settings.pageGap)
                    }
                    SetRow(label: "Auto-scroll speed") { Slider(value: $library.settings.autoScrollSpeed, in: 30...600).controlSize(.small).frame(width: 150) }
                    SetRow(label: "Continuous scrolling between chapters") { MonoSwitch(isOn: $library.settings.seamlessChapters) }
                } else {
                    SetRow(label: "Tap zones") { MonoChoice(options: TapZones.allCases.map { ($0, $0.label) }, selection: $library.settings.tapZones) }
                    SetRow(label: "Swap back and forward") { MonoSwitch(isOn: $library.settings.invertTapZones) }
                    SetRow(label: "Two pages at a time") { MonoSwitch(isOn: $library.settings.doublePage) }
                    if library.settings.doublePage {
                        SetRow(label: "First page alone (cover)") { MonoSwitch(isOn: $library.settings.doubleFirstAlone) }
                    } else {
                        SetRow(label: "Split wide pages in two") { MonoSwitch(isOn: $library.settings.splitWidePages) }
                    }
                    SetRow(label: "Crop white and black margins") { MonoSwitch(isOn: $library.settings.cropBorders) }
                }
                SetRow(label: "Skip chapters already read") { MonoSwitch(isOn: $library.settings.skipReadChapters) }
                SetRow(label: "Background") {
                    MonoChoice(options: [(ReaderBackground.black, "black"), (.gray, "gray"), (.white, "white"), (.auto, "auto")], selection: $library.settings.readerBackground)
                }
                SetRow(label: "Show page number") { MonoSwitch(isOn: $library.settings.showPageNumber) }
                SetRow(label: "Keep screen awake") { MonoSwitch(isOn: $library.settings.keepAwake) }
                HStack { TextAction(title: "keyboard shortcuts") { showShortcuts = true }; Spacer() }.padding(.vertical, 12)
            }
        }
    }

    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { TextAction(title: "← back") { showShortcuts = false }; Spacer() }.padding(.vertical, 8)
            ForEach([("Space / ↓ ↑", "scroll"), ("[ ]", "previous / next chapter"), ("A", "auto-scroll"), ("+ − 0", "zoom, reset"),
                     ("pinch · double-click", "zoom"), ("C", "chapters"), ("B", "bookmark"), ("F", "full screen"), ("M", "show controls"),
                     ("right-click a page", "copy, save, share, use as cover"), ("Esc", "back")], id: \.0) { k, d in
                HStack(alignment: .firstTextBaseline) {
                    Text(k).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 12)
                    Text(d).font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 7).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
    }
}

/// Opt-in (Reader settings › Show page number): just the number, nothing else.
struct PageNumberPill: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        Text("\(model.index + 1) / \(model.pages.count)").font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.black.opacity(0.6), in: Capsule()).foregroundStyle(.white.opacity(0.85))
            .padding(12)
    }
}
