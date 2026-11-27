import AppKit
import Combine
import FolioCore
import QuartzCore
import SwiftUI

// Native reader canvases. Zoom is NSScrollView magnification: it magnifies the *viewport* and
// never changes the page layout, so page tracking, progress and chapter flow are unaffected.

struct ReaderLook: Equatable {
    var widthFraction: CGFloat
    var gap: CGFloat
    var background: ReaderBackground
    var autoScrollSpeed: CGFloat
}

/// Flipped document view that forwards clicks (single = controls / page turn, double = zoom).
final class CanvasDocView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    var onClick: ((NSPoint) -> Void)?
    var onDoubleClick: ((NSPoint) -> Void)?
    /// The page menu for a point: right-click, or press and hold.
    var menuAt: ((NSPoint) -> NSMenu?)?
    private var pending: DispatchWorkItem?
    private var hold: DispatchWorkItem?
    private var downAt: NSPoint = .zero
    private var heldOpen = false

    override func menu(for e: NSEvent) -> NSMenu? { menuAt?(convert(e.locationInWindow, from: nil)) }

    override func mouseDown(with e: NSEvent) {
        downAt = e.locationInWindow
        heldOpen = false
        hold?.cancel()
        let p = convert(e.locationInWindow, from: nil)
        let w = DispatchWorkItem { [weak self] in
            guard let self, let m = self.menuAt?(p) else { return }
            self.heldOpen = true
            self.pending?.cancel(); self.pending = nil
            NSMenu.popUpContextMenu(m, with: e, for: self)
        }
        hold = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    override func mouseDragged(with e: NSEvent) {
        if hypot(e.locationInWindow.x - downAt.x, e.locationInWindow.y - downAt.y) >= 6 { hold?.cancel() }
        super.mouseDragged(with: e)
    }
    override func mouseUp(with e: NSEvent) {
        hold?.cancel()
        if heldOpen { heldOpen = false; return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(e.locationInWindow.x - downAt.x, e.locationInWindow.y - downAt.y) < 6 else { return }   // a drag, not a click
        if e.clickCount >= 2 {
            pending?.cancel(); pending = nil
            onDoubleClick?(p)
        } else {
            let w = DispatchWorkItem { [weak self] in self?.onClick?(p) }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: w)
        }
    }
}

final class CanvasScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }   // keyboard stays with the SwiftUI reader
}

/// A page container: shows its number and a small spinner while empty, then the image.
final class PageTile: CALayer {
    let label = CATextLayer()
    let spinner = CAShapeLayer()
    var key = ""
    var failed = false
    /// Long webtoon pages are taller than the GPU can draw as one texture (they'd show as an empty, dark page),
    /// so above `sliceHeight` pixels the image is shown as a stack of bands instead. (Width is already capped
    /// at 2000 px when pages are decoded, so only height needs slicing.)
    private var slices: [CALayer] = []
    private var sliceFractions: [CGRect] = []
    private(set) var hasImage = false
    static let sliceHeight = 4096

    /// Whether y grows downward inside this layer (the reader's document view is flipped, and that carries down).
    private var flippedInside: Bool {
        var f = isGeometryFlipped, l = superlayer
        while let p = l { if p.isGeometryFlipped { f.toggle() }; l = p.superlayer }
        return f
    }

    func setImage(_ cg: CGImage?) {
        for s in slices { s.removeFromSuperlayer() }
        slices = []; sliceFractions = []
        hasImage = cg != nil
        guard let cg, cg.height > Self.sliceHeight else { contents = cg; return }
        contents = nil
        let h = cg.height
        var y = 0
        while y < h {
            let band = min(Self.sliceHeight, h - y)
            if let part = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: band)) {
                let l = CALayer()
                l.contents = part
                l.contentsGravity = .resize
                l.minificationFilter = .trilinear
                l.contentsScale = contentsScale
                l.isOpaque = true
                l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
                insertSublayer(l, at: UInt32(slices.count))      // under the label and spinner
                slices.append(l)
                sliceFractions.append(CGRect(x: 0, y: CGFloat(y) / CGFloat(h), width: 1, height: CGFloat(band) / CGFloat(h)))
            }
            y += band
        }
        setNeedsLayout()
    }

    override init() {
        super.init()
        contentsGravity = .resize
        minificationFilter = .trilinear
        masksToBounds = true
        label.fontSize = 12
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.alignmentMode = .center
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        addSublayer(label)
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: 9, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
        spinner.path = path
        spinner.fillColor = nil
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.bounds = CGRect(x: -10, y: -10, width: 20, height: 20)
        spinner.isHidden = true
        addSublayer(spinner)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSublayers() {
        super.layoutSublayers()
        for (l, f) in zip(slices, sliceFractions) {       // image rows run top-down; layer space is bottom-up unless flipped
            let y = flippedInside ? f.minY : 1 - f.maxY
            l.frame = CGRect(x: 0, y: (y * bounds.height).rounded(), width: bounds.width,
                             height: (f.height * bounds.height).rounded(.up) + 1)
        }
        if label.isWrapped, let s = label.string as? String {
            // A message: wrapped to a readable width, centred in the page.
            let w = max(60, min(bounds.width - 48, 460))
            let font = NSFont.systemFont(ofSize: 14)
            let h = ceil((s as NSString).boundingRect(with: CGSize(width: w, height: 1000), options: [.usesLineFragmentOrigin],
                                                      attributes: [.font: font]).height) + 4
            label.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.midY - h / 2, width: w, height: h)
        } else {
            label.frame = CGRect(x: 0, y: bounds.midY + 10, width: bounds.width, height: 18)
        }
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY - 10)
    }

    /// Empty container: page number + spinner.
    func setLoading(_ number: Int, ink: NSColor) {
        label.isHidden = false
        label.isWrapped = false
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium); label.fontSize = 12
        label.string = "\(number)"
        label.foregroundColor = ink.withAlphaComponent(0.4).cgColor
        spinner.strokeColor = ink.withAlphaComponent(0.45).cgColor
        spinner.isHidden = false
        if spinner.animation(forKey: "spin") == nil {
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.fromValue = 0; r.toValue = -2 * Double.pi; r.duration = 0.9; r.repeatCount = .infinity
            spinner.add(r, forKey: "spin")
        }
        setNeedsLayout()
    }

    /// Plain message (errors) or nothing.
    func setStatus(_ text: String?, ink: NSColor) {
        spinner.isHidden = true
        spinner.removeAllAnimations()
        label.isHidden = text == nil
        label.isWrapped = true
        label.truncationMode = .none
        label.font = NSFont.systemFont(ofSize: 14); label.fontSize = 14
        label.string = text
        label.foregroundColor = ink.withAlphaComponent(0.55).cgColor
        setNeedsLayout()
    }
}

private func noAnim(_ f: () -> Void) {
    CATransaction.begin(); CATransaction.setDisableActions(true); f(); CATransaction.commit()
}

// MARK: - Webtoon strip

struct WebtoonStrip: NSViewRepresentable {
    @ObservedObject var model: ReaderModel
    let source: Source
    let look: ReaderLook

    func makeCoordinator() -> StripController { StripController(model: model, source: source) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ v: NSScrollView, context: Context) {
        context.coordinator.update(items: model.items, look: look, command: model.command, autoScroll: model.autoScroll)
    }
    static func dismantleNSView(_ v: NSScrollView, coordinator: StripController) { coordinator.teardown() }
}

@MainActor
final class StripController: NSObject {
    struct Slot { let item: ReaderItem; var y: CGFloat; var h: CGFloat }

    let model: ReaderModel
    let source: Source
    let scrollView = CanvasScrollView()
    let doc = CanvasDocView()

    private var items: [ReaderItem] = []
    private var slots: [Slot] = []
    private var slotIndex: [String: Int] = [:]
    private var slotByPage: [String: Int] = [:]      // page image key → slot
    private var tiles: [String: PageTile] = [:]
    private var hosts: [String: NSView] = [:]
    private var loading: Set<String> = []
    private var loadTasks: [String: Task<Void, Never>] = [:]      // tile id → its load, cancelled when the tile is dropped
    private var lastTop: CGFloat = 0
    private var look = ReaderLook(widthFraction: 0.62, gap: 0, background: .black, autoScrollSpeed: 140)
    private var lastCommand: UUID?
    private var pendingAnchor: (id: String, offset: CGFloat)?
    private var layoutWidth: CGFloat = 0
    private var lastReported: [String] = []
    private var autoLink: CADisplayLink?
    private var autoLast: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    /// Typical page shape per chapter, so unloaded pages get a near-correct placeholder height.
    private var chapterAspect: [String: CGFloat] = [:]

    init(model: ReaderModel, source: Source) {
        self.model = model
        self.source = source
        super.init()
        scrollView.hasVerticalScroller = false      // no scrollbar: the page scrubber is the only position control
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 4
        scrollView.drawsBackground = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = doc
        doc.wantsLayer = true
        doc.layerContentsRedrawPolicy = .never
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didScroll() }
        })
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout(keepAnchor: true) }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.model.zoomChanged(self.scrollView.magnification, toast: true) }
        })
        doc.onClick = { [weak self] p in self?.click(p) }
        doc.onDoubleClick = { [weak self] p in self?.toggleZoom(at: p) }
        doc.menuAt = { [weak self] p in self?.pageMenu(at: p) }
        model.scrubHandler = { [weak self] pos in self?.scrubTo(pos) }
        model.refreshHandler = { [weak self] in self?.didScroll() }
        Images.shared.onAspect = { [weak self] key in self?.aspectArrived(key) }
    }

    func teardown() {
        model.scrubHandler = nil
        model.refreshHandler = nil
        Images.shared.onAspect = nil
        autoLink?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: updates from SwiftUI

    func update(items new: [ReaderItem], look l: ReaderLook, command: ScrollCommand?, autoScroll: Bool) {
        if l != look {
            let relayoutNeeded = l.widthFraction != look.widthFraction || l.gap != look.gap
            look = l
            scrollView.backgroundColor = NSColor(l.background.color)
            tiles.values.forEach { $0.backgroundColor = NSColor(l.background.ink).withAlphaComponent(0.035).cgColor }
            if relayoutNeeded { relayout(keepAnchor: true) }
        }
        if new != items { apply(new) }
        if let c = command, c.id != lastCommand { lastCommand = c.id; run(c) }
        setAutoScroll(autoScroll)
    }

    private func apply(_ new: [ReaderItem]) {
        let appended = !items.isEmpty && new.count > items.count && Array(new.prefix(items.count)) == items
        let prepended = !items.isEmpty && new.count > items.count && Array(new.suffix(items.count)) == items
        if prepended {
            // A chapter was attached above: shift everything down by its height and move the viewport by the
            // same amount, so the page you're on doesn't move at all.
            let added = Array(new.prefix(new.count - items.count))
            var heights: [CGFloat] = added.map { height(for: $0) }
            let total = heights.reduce(0, +) + look.gap * CGFloat(added.count)
            var front: [Slot] = []
            var y: CGFloat = 0
            for (k, it) in added.enumerated() { front.append(Slot(item: it, y: y, h: heights[k])); y += heights[k] + look.gap }
            heights = []
            for k in slots.indices { slots[k].y += total }
            slots = front + slots
            items = new
            slotIndex = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1.id, $0) })
            slotByPage = [:]
            for (i, it) in new.enumerated() { if case .page(_, let p, _, _) = it.kind { slotByPage[Images.key(p)] = i } }
            let clip = scrollView.contentView
            noAnim {
                resizeDoc()
                for (id, t) in tiles { if let i = slotIndex[id] { position(t, slots[i]) } }
                for (id, h) in hosts { if let i = slotIndex[id] { position(h, slots[i]) } }
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + total))
                scrollView.reflectScrolledClipView(clip)
            }
            lastTop += total
        } else if appended {
            let start = items.count
            items = new
            var y = slots.last.map { $0.y + $0.h + look.gap } ?? 0
            for i in start..<new.count {
                let h = height(for: new[i])
                slots.append(Slot(item: new[i], y: y, h: h))
                slotIndex[new[i].id] = i
                if case .page(_, let p, _, _) = new[i].kind { slotByPage[Images.key(p)] = i }
                y += h + look.gap
            }
            resizeDoc()
        } else {
            // Neither a plain prepend nor a plain append (e.g. both neighbours attached at once): keep what the
            // reader is looking at, exactly as a resize does. A different stream (new chapter opened) finds no anchor.
            let anchor = items.isEmpty ? nil : currentAnchor()
            tiles.values.forEach { $0.removeFromSuperlayer() }; tiles = [:]
            hosts.values.forEach { $0.removeFromSuperview() }; hosts = [:]
            items = new
            slotIndex = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1.id, $0) })
            slotByPage = [:]
            for (i, it) in new.enumerated() { if case .page(_, let p, _, _) = it.kind { slotByPage[Images.key(p)] = i } }
            slots = new.map { Slot(item: $0, y: 0, h: 0) }
            layoutAll()
            if let a = anchor, let i = slotIndex[a.id] { scrollTo(y: slots[i].y + slots[i].h * a.offset, animated: false) }
        }
        didScroll()
    }

    // MARK: layout

    private var columnWidth: CGFloat {
        let w = layoutWidth > 0 ? layoutWidth : 900
        return max(min(w, 320), min(w, w * look.widthFraction))
    }
    private var columnX: CGFloat { max(0, (max(layoutWidth, columnWidth) - columnWidth) / 2) }

    private func height(for item: ReaderItem) -> CGFloat {
        switch item.kind {
        case .divider: return 44
        case .transition: return 340
        case .page(let c, let p, _, _):
            let a = Images.shared.aspect(Images.key(p)) ?? chapterAspect[c.url] ?? (1 / 1.45)
            return (columnWidth / a).rounded()
        }
    }

    private func layoutAll() {
        layoutWidth = scrollView.frame.width
        var y: CGFloat = 0
        for i in slots.indices {
            slots[i].y = y
            slots[i].h = height(for: slots[i].item)
            y += slots[i].h + look.gap
        }
        resizeDoc()
        noAnim { for (id, t) in tiles { if let i = slotIndex[id] { position(t, slots[i]) } } }
        for (id, h) in hosts { if let i = slotIndex[id] { position(h, slots[i]) } }
    }

    private func resizeDoc() {
        let total = max(slots.last.map { $0.y + $0.h } ?? 0, 1)
        doc.frame = NSRect(x: 0, y: 0, width: max(layoutWidth, 1), height: total)
    }

    /// Re-lays out (width/gap/window size changed) while keeping the same spot on screen.
    func relayout(keepAnchor: Bool) {
        let anchor = pendingAnchor ?? (keepAnchor ? currentAnchor() : nil)
        layoutAll()
        if let a = anchor, let i = slotIndex[a.id] {
            scrollTo(y: slots[i].y + slots[i].h * a.offset, animated: false)
        }
        didScroll()
    }

    /// What's at the top of the screen, as "page-id+pixels into it" (debug).
    func anchorDescription() -> String {
        let b = scrollView.contentView.bounds
        guard let i = slotAt(y: b.minY) else { return "-" }
        return "\(slots[i].item.id.replacingOccurrences(of: "p|", with: ""))@\(Int(((b.minY - slots[i].y) / max(1, slots[i].h)) * 1000))‰"
    }

    private func currentAnchor() -> (id: String, offset: CGFloat)? {
        let b = scrollView.contentView.bounds
        guard let i = slotAt(y: b.minY + b.height * 0.2) else { return nil }
        let s = slots[i]
        return (s.item.id, s.h > 0 ? (b.minY - s.y) / s.h : 0)
    }

    private func slotAt(y: CGFloat) -> Int? {
        guard !slots.isEmpty else { return nil }
        var lo = 0, hi = slots.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if slots[mid].y <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func position(_ layer: CALayer, _ s: Slot) {
        layer.frame = CGRect(x: columnX, y: s.y, width: columnWidth, height: s.h)
    }

    private func position(_ v: NSView, _ s: Slot) {
        let w = min(columnWidth, 460)
        v.frame = NSRect(x: (max(layoutWidth, w) - w) / 2, y: s.y, width: w, height: s.h)
    }

    // MARK: scrolling → virtualisation + reading position

    func didScroll() {
        guard !slots.isEmpty else { return }
        let b = scrollView.contentView.bounds
        let keep = b.insetBy(dx: 0, dy: -b.height * 4)
        // Look further ahead in the direction you're travelling, so fast scrolls land on loaded pages.
        let down = b.minY >= lastTop; lastTop = b.minY
        let want = CGRect(x: b.minX, y: b.minY - b.height * (down ? 1 : 3), width: b.width, height: b.height * 5)
        guard let first = slotAt(y: want.minY) else { return }
        var i = first
        while i < slots.count, slots[i].y <= want.maxY { ensureView(i); i += 1 }
        // Drop far-away tiles to bound memory (vertical distance only — zoom/pan moves x).
        func near(_ id: String) -> Bool {
            guard let k = slotIndex[id] else { return false }
            return slots[k].y + slots[k].h >= keep.minY && slots[k].y <= keep.maxY
        }
        for (id, t) in tiles where !near(id) {
            t.removeFromSuperlayer(); tiles[id] = nil
            if let task = loadTasks[id] { task.cancel(); loadTasks[id] = nil; loading.remove(t.key) }     // nobody's waiting for it any more
        }
        for (id, v) in hosts where !near(id) { v.removeFromSuperview(); hosts[id] = nil }
        // Reading line at 20% from the top decides "the current page".
        guard let cur = slotAt(y: b.minY + b.height * 0.2) else { return }
        if case .page(_, _, let pi, _) = slots[cur].item.kind, !model.scrub.dragging {
            let s = slots[cur]
            let pos = Double(pi) + Double(max(0, min(1, (b.minY + b.height * 0.2 - s.y) / max(1, s.h))))
            if abs(pos - model.scrub.position) > 0.003 { model.scrub.position = pos }
        }
        var ids: [String] = []
        var j = cur
        while j < slots.count, slots[j].y < b.maxY { ids.append(slots[j].item.id); j += 1 }
        if ids != lastReported { lastReported = ids; model.visible(ids) }
    }

    private func ensureView(_ i: Int) {
        let s = slots[i]
        switch s.item.kind {
        case .page(let c, let p, let n, let total):
            let allowed = model.mayLoad(c, index: n, count: total)
            if let t = tiles[s.item.id] {
                // A neighbour chapter you've now scrolled into: start the pages that were held back.
                if allowed, !t.hasImage, !t.failed, !loading.contains(t.key) { load(p, id: s.item.id, number: n + 1) }
                return
            }
            let t = PageTile()
            t.key = Images.key(p)
            t.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            t.backgroundColor = NSColor(look.background.ink).withAlphaComponent(0.035).cgColor
            noAnim {
                position(t, s)
                doc.layer?.addSublayer(t)
            }
            tiles[s.item.id] = t
            if let img = Images.shared.cached(t.key) { show(img, in: t, slot: s.item.id) }
            else { t.setLoading(n + 1, ink: NSColor(look.background.ink)); if allowed { load(p, id: s.item.id, number: n + 1) } }
        case .divider(let c):
            guard hosts[s.item.id] == nil else { return }
            let v = NSHostingView(rootView: ChapterDivider(chapter: c, ink: look.background.ink))
            position(v, s); doc.addSubview(v); hosts[s.item.id] = v
        case .transition(let from, let to):
            guard hosts[s.item.id] == nil else { return }
            let v = NSHostingView(rootView: TransitionCard(model: model, from: from, to: to, ink: look.background.ink)
                .padding(.vertical, 40))
            position(v, s); doc.addSubview(v); hosts[s.item.id] = v
        }
    }

    private func load(_ p: PageRef, id: String, number: Int) {
        let key = Images.key(p)
        guard !loading.contains(key) else { return }
        loading.insert(key)
        loadTasks[id] = Task { [weak self] in
            let img = await Images.shared.page(p, source: self?.source ?? EmptySource())
            guard let self else { return }
            self.loading.remove(key)
            self.loadTasks[id] = nil
            guard !Task.isCancelled, let t = self.tiles[id] else { return }
            if let img { self.show(img, in: t, slot: id, fade: true) }
            else {
                t.failed = true
                let why = Images.shared.failure(key) ?? "Couldn\u{2019}t load this page. Click to retry."
                t.setStatus("Page \(number)\n\(why)", ink: NSColor(self.look.background.ink))
            }
        }
    }

    private func show(_ img: NSImage, in t: PageTile, slot id: String, fade: Bool = false) {
        if fade {       // the empty container fills in rather than popping
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0; f.toValue = 1; f.duration = 0.2
            t.add(f, forKey: "fadeIn")
        }
        noAnim {
            t.setImage(img.cgImage(forProposedRect: nil, context: nil, hints: nil))
            t.isOpaque = true                 // pages have no transparency: skip blending in the compositor
            t.backgroundColor = nil
            t.failed = false
            t.setStatus(nil, ink: .white)
        }
        guard let i = slotIndex[id] else { return }
        let aspect = max(0.05, img.size.width / max(1, img.size.height))
        if case .page(let c, _, _, _) = slots[i].item.kind, chapterAspect[c.url] == nil { chapterAspect[c.url] = aspect }
        resizeSlot(i, to: (columnWidth / aspect).rounded())
    }

    /// A page's real height is known: shift everything below it; if it's above the viewport,
    /// move the viewport by the same amount so what you're reading doesn't jump.
    private func resizeSlot(_ i: Int, to h: CGFloat) {
        let delta = h - slots[i].h
        guard abs(delta) >= 1 else { return }
        let clip = scrollView.contentView
        let top = clip.bounds.minY
        let oldH = slots[i].h
        let aboveViewport = slots[i].y < top - 0.5
        // Fully above the screen → shift by the whole change. Straddling the top edge → shift in
        // proportion, so the same part of that image stays at the top of the screen.
        let shift = !aboveViewport ? 0 : (slots[i].y + oldH <= top ? delta : delta * (top - slots[i].y) / max(1, oldH))
        let before = DebugHook.enabled ? anchorDescription() : ""
        slots[i].h = h
        for k in (i + 1)..<slots.count { slots[k].y += delta }
        noAnim {
            resizeDoc()
            for k in i..<slots.count {
                let id = slots[k].item.id
                if let t = tiles[id] { position(t, slots[k]) }
                if let v = hosts[id] { position(v, slots[k]) }
            }
            if aboveViewport {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + shift))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        if DebugHook.enabled {
            let after = anchorDescription()
            DebugHook.log("resize slot=\(slots[i].item.id.split(separator: "|").last ?? "") delta=\(Int(delta)) above=\(aboveViewport) anchor \(before) -> \(after) \(before == after ? "STABLE" : "MOVED")")
        }
    }

    /// Scrubber drag: put fractional page `pos` of the current chapter at the reading line.
    private func scrubTo(_ pos: Double) {
        let pages = model.pages.count
        guard pages > 0 else { return }
        let i = min(pages - 1, max(0, Int(pos.rounded(.down))))
        guard let k = slotIndex[ReaderModel.pageID(model.chapter, i)] else { return }
        let s = slots[k]
        let y = s.y + CGFloat(pos - Double(i)) * s.h - scrollView.contentView.bounds.height * 0.2
        scrollTo(y: y, animated: false)
    }

    /// A page's real shape arrived (read-ahead) before the page was shown: settle its slot now so
    /// nothing below it moves later while you scroll.
    private func aspectArrived(_ key: String) {
        guard let i = slotByPage[key], i < slots.count, let a = Images.shared.aspect(key),
              case .page(let c, _, _, _) = slots[i].item.kind else { return }
        if chapterAspect[c.url] == nil { chapterAspect[c.url] = max(0.05, a) }
        if tiles[slots[i].item.id]?.hasImage == true { return }       // already showing the real image
        resizeSlot(i, to: (columnWidth / max(0.05, a)).rounded())
    }

    // MARK: commands

    private func run(_ c: ScrollCommand) {
        let b = scrollView.contentView.bounds
        switch c.kind {
        case .toItem(let id, let animated):
            guard let i = slotIndex[id] else { return }
            if layoutWidth == 0 || scrollView.frame.width == 0 { pendingAnchor = (id, 0) }
            scrollTo(y: slots[i].y, animated: animated)
        case .byViewport(let f): scrollTo(y: b.minY + b.height * f, animated: true)
        case .byPoints(let d): scrollTo(y: b.minY + d / scrollView.magnification, animated: true, fast: true)
        case .zoomBy(let f): zoom(to: scrollView.magnification * f, at: NSPoint(x: b.midX, y: b.midY), toast: true)
        case .zoomTo(let z): zoom(to: z, at: NSPoint(x: b.midX, y: b.midY), toast: true)
        }
    }

    private func scrollTo(y: CGFloat, animated: Bool, fast: Bool = false) {
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let p = NSPoint(x: clip.bounds.minX, y: min(max(0, y), maxY))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fast ? 0.12 : 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(p)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.scrollView.reflectScrolledClipView(clip) }
            }
        } else {
            clip.setBoundsOrigin(p)
            scrollView.reflectScrolledClipView(clip)
            if layoutWidth > 0 { pendingAnchor = nil }
        }
    }

    private func zoom(to z: CGFloat, at p: NSPoint, toast: Bool) {
        let m = min(scrollView.maxMagnification, max(scrollView.minMagnification, z))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            scrollView.animator().setMagnification(m, centeredAt: p)
        }
        model.zoomChanged(m, toast: toast)
    }

    private func toggleZoom(at p: NSPoint) {
        zoom(to: scrollView.magnification > 1.01 ? 1 : 2, at: p, toast: true)
    }

    private func click(_ p: NSPoint) {
        if let i = slotAt(y: p.y), let t = tiles[slots[i].item.id], t.failed,
           case .page(_, let ref, let n, _) = slots[i].item.kind {
            t.failed = false
            t.setLoading(n + 1, ink: NSColor(look.background.ink))
            load(ref, id: slots[i].item.id, number: n + 1)
            return
        }
        model.toggleControls()
    }

    private func pageMenu(at p: NSPoint) -> NSMenu? {
        guard let i = slotAt(y: p.y), slots[i].y <= p.y, p.y <= slots[i].y + slots[i].h,
              case .page(let c, let ref, let n, _) = slots[i].item.kind, tiles[slots[i].item.id]?.hasImage == true else { return nil }
        return PageMenu.make(page: ref, number: n + 1, model: model, source: source, view: doc, at: p, cropToggle: false, chapter: c)
    }

    // MARK: auto-scroll

    /// Driven by the display's own link, so it ticks once per refresh (120 Hz on ProMotion).
    private func setAutoScroll(_ on: Bool) {
        if on, autoLink == nil {
            let l = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            autoLast = 0
            l.add(to: .main, forMode: .common)
            autoLink = l
        } else if !on, let l = autoLink {
            l.invalidate(); autoLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = autoLast == 0 ? 0 : min(0.1, now - autoLast); autoLast = now
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let y = clip.bounds.minY + look.autoScrollSpeed * dt / scrollView.magnification
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: min(y, maxY)))
        scrollView.reflectScrolledClipView(clip)
        if y >= maxY { model.autoScroll = false }
    }
}

// MARK: - Paged canvas

struct PagedCanvas: NSViewRepresentable {
    @ObservedObject var model: ReaderModel
    let source: Source
    let background: ReaderBackground

    func makeCoordinator() -> PagedController { PagedController(model: model, source: source) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ v: NSScrollView, context: Context) {
        let c = context.coordinator
        c.scrollView.backgroundColor = NSColor(background.color)
        c.refresh()
        if let cmd = model.command, cmd.id != c.lastCommand { c.lastCommand = cmd.id; c.run(cmd) }
    }
    static func dismantleNSView(_ v: NSScrollView, coordinator: PagedController) { coordinator.teardown() }
}

/// One page, or two side by side (double-page), or one half of a wide page (split) — drawn as 1–2 tiles
/// that always fit the window together.
@MainActor
final class PagedController: NSObject {
    let model: ReaderModel
    let source: Source
    let scrollView = CanvasScrollView()
    let doc = CanvasDocView()
    var lastCommand: UUID?

    private struct Slot { var page: Int; var key: String; var tile: PageTile; var aspect: CGFloat = 0.7 }
    private var tiles: [PageTile] = []
    private var slots: [Slot] = []
    private var signature = ""
    private var settingsWatch: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var settings: ReaderPrefs { model.prefs }

    init(model: ReaderModel, source: Source) {
        self.model = model
        self.source = source
        super.init()
        scrollView.hasVerticalScroller = false      // no scrollbar: the page scrubber is the only position control
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 4
        scrollView.documentView = doc
        doc.wantsLayer = true
        scrollView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.model.zoomChanged(self.scrollView.magnification, toast: true) }
        })
        doc.onClick = { [weak self] p in self?.click(p) }
        doc.onDoubleClick = { [weak self] p in self?.toggleZoom(at: p) }
        // Crop, double-page and split are library settings: redraw when they flip (SwiftUI doesn't rebuild this canvas for them).
        settingsWatch = model.$prefs.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        // A page's shape arriving can change which pages count as wide, so spreads re-pair.
        Images.shared.onAspect = { [weak self] _ in self?.refresh() }
        doc.menuAt = { [weak self] p in
            guard let self, let s = self.slots.first(where: { $0.tile.frame.contains(p) }) ?? self.slots.first, s.tile.contents != nil,
                  self.model.pages.indices.contains(s.page) else { return nil }
            return PageMenu.make(page: self.model.pages[s.page], number: s.page + 1, model: self.model,
                                 source: self.source, view: self.doc, at: p, cropToggle: true)
        }
    }

    func teardown() {
        Images.shared.onAspect = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }

    func layout() {
        doc.frame = NSRect(origin: .zero, size: scrollView.frame.size)
        fit()
    }

    /// Brings the screen in line with the model (page, spread, half, settings).
    func refresh() {
        guard !model.pages.isEmpty else { return }
        var pageIdx = model.displayedPages.filter { model.pages.indices.contains($0) }
        if pageIdx.isEmpty { pageIdx = [max(0, min(model.index, model.pages.count - 1))] }
        let double = pageIdx.count == 2
        let rtl = model.mode == .rightToLeft
        if double && rtl { pageIdx.reverse() }                  // right-to-left: the first page sits on the right
        let split = model.splitting && !double && model.isWide(pageIdx[0])
        let sig = pageIdx.map { Images.key(model.pages[$0]) }.joined(separator: ",") + "|\(split ? model.half : -1)|\(settings.cropBorders)|\(model.mode.rawValue)"
        if sig == signature { return }
        signature = sig
        if doc.frame.size != scrollView.frame.size { layout() }
        while tiles.count < pageIdx.count {
            let t = PageTile()
            t.contentsGravity = .resize
            t.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            doc.layer?.addSublayer(t)
            tiles.append(t)
        }
        for (i, t) in tiles.enumerated() where i >= pageIdx.count { noAnim { t.isHidden = true; t.contents = nil } }
        slots = pageIdx.enumerated().map { i, p in
            let t = tiles[i]
            noAnim { t.isHidden = false; t.contents = nil; t.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1) }
            return Slot(page: p, key: Images.key(model.pages[p]), tile: t)
        }
        fit()
        for i in slots.indices {
            let key = slots[i].key
            if let img = Images.shared.cached(key) { apply(img, to: i, split: split); continue }
            slots[i].tile.setStatus("Loading…", ink: .gray)
            let ref = model.pages[slots[i].page]
            Task { [weak self] in
                guard let self else { return }
                let img = await Images.shared.page(ref, source: self.source)
                guard self.signature == sig, i < self.slots.count, self.slots[i].key == key else { return }
                if let img { self.apply(img, to: i, split: split) } else {
                    self.slots[i].tile.setStatus((Images.shared.failure(key) ?? "Couldn\u{2019}t load this page").replacingOccurrences(of: " Click to retry.", with: " Turn the page to retry.").replacingOccurrences(of: " Click to verify.", with: ""), ink: .gray)
                }
            }
        }
    }

    /// Shows `img` in slot `i`, zoomed past plain margins and/or cut to one half of a wide page.
    private func apply(_ img: NSImage, to i: Int, split: Bool) {
        guard i < slots.count, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        var r = CGRect(x: 0, y: 0, width: 1, height: 1)                 // image space, origin top-left
        if settings.cropBorders, let c = BorderCrop.content(of: cg) { r = c }
        if split {
            let firstIsLeft = model.mode != .rightToLeft
            let left = (model.half == 0) == firstIsLeft
            r = CGRect(x: left ? r.minX : r.minX + r.width / 2, y: r.minY, width: r.width / 2, height: r.height)
        }
        slots[i].aspect = (CGFloat(cg.width) * r.width) / (CGFloat(cg.height) * r.height)
        let t = slots[i].tile
        noAnim { t.contents = cg; t.contentsRect = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }   // layer space starts bottom-left
        t.setStatus(nil, ink: .white)
        fit()
    }

    /// Lays the tiles side by side, as large as fits the window.
    private func fit() {
        guard !slots.isEmpty else { return }
        let box = CGRect(origin: .zero, size: scrollView.frame.size).insetBy(dx: 0, dy: 6)
        let total = slots.reduce(CGFloat(0)) { $0 + $1.aspect }
        guard total > 0, box.width > 0, box.height > 0 else { return }
        let h = min(box.height, box.width / total)
        var x = box.midX - total * h / 2
        noAnim {
            for s in slots { let w = s.aspect * h; s.tile.frame = CGRect(x: x, y: box.midY - h / 2, width: w, height: h); x += w }
        }
    }

    func run(_ c: ScrollCommand) {
        let b = scrollView.contentView.bounds
        switch c.kind {
        case .zoomBy(let f): zoom(to: scrollView.magnification * f, at: NSPoint(x: b.midX, y: b.midY))
        case .zoomTo(let z): zoom(to: z, at: NSPoint(x: b.midX, y: b.midY))
        default: break
        }
    }

    private func zoom(to z: CGFloat, at p: NSPoint) {
        let m = min(scrollView.maxMagnification, max(1, z))
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; scrollView.animator().setMagnification(m, centeredAt: p) }
        model.zoomChanged(m, toast: true)
    }

    private func toggleZoom(at p: NSPoint) { zoom(to: scrollView.magnification > 1.01 ? 1 : 2, at: p) }

    /// Click zones are relative to what's on screen (works the same at any zoom).
    private func click(_ p: NSPoint) {
        let b = scrollView.contentView.bounds
        let st = settings
        let x = (p.x - b.minX) / max(1, b.width)
        let y = (p.y - b.minY) / max(1, b.height)
        let flip = (model.mode == .rightToLeft) != st.invertTapZones
        switch st.tapZones.action(x: x, y: y) {
        case .back: flip ? model.forward() : model.back()
        case .forward: flip ? model.back() : model.forward()
        case .controls: model.toggleControls()
        }
    }
}

/// Placeholder for the weak-self fallback above; never actually used to load.
final class EmptySource: Source, @unchecked Sendable {
    let id = "none"; let name = "none"
    func popular(page: Int) async throws -> SeriesPage { SeriesPage(series: [], hasNextPage: false) }
    func search(_ query: String, page: Int) async throws -> SeriesPage { SeriesPage(series: [], hasNextPage: false) }
    func details(_ s: Series) async throws -> Series { s }
    func chapters(_ s: Series) async throws -> [Chapter] { [] }
    func pages(_ c: Chapter, of s: Series) async throws -> [PageRef] { [] }
    func coverData(_ s: Series) async throws -> Data? { nil }
}
