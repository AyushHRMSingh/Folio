import AppKit
import Combine
import FolioCore
import SwiftUI


struct BarButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14.5, weight: .medium))
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
        GeometryReader { g in bar(width: g.size.width) }
            .frame(height: (fullscreen ? 12 : 44) + 40)
    }

    private func bar(width: CGFloat) -> some View {
        let page = width * CGFloat(model.prefs.webtoonWidth)
        let margin = max(0, (width - page) / 2) - 16 - 6          // room left of the page, minus bar padding/gap
        let budget = margin - 54 - 17                              // capsule chrome: padding, arrow, spacing, chevron
        let showChapter = budget >= 190
        let showTitle = budget >= 40
        return HStack(spacing: 12) {
            // Where you are
            HStack(spacing: 15) {
                Button { model.close() } label: { Image(systemName: "chevron.left").font(.system(size: 15.5, weight: .medium)) }
                    .buttonStyle(.plain).help("Back (Esc)")
                Button { model.popover = .chapters } label: {
                    HStack(spacing: 10) {
                        if showTitle {
                            Text(model.series.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: showChapter ? 110 : budget, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        }
                        if showChapter {
                            Text(model.chapter.name).font(.system(size: 13, design: .monospaced)).opacity(0.6).lineLimit(1)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).opacity(0.6)
                    }
                }
                .buttonStyle(.plain).help("All chapters (C)")
                .popover(isPresented: Binding(get: { model.popover == .chapters }, set: { if !$0 { model.popover = nil } }), arrowEdge: .bottom) {
                    ChapterPicker(model: model, library: library)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.black.opacity(0.88), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            Spacer(minLength: 20)
            // Tools
            HStack(spacing: 20) {
                if model.mode == .webtoon {
                    Button { model.toggleAutoScroll() } label: { Image(systemName: model.autoScroll ? "pause.fill" : "play.fill").font(.system(size: 15.5)) }
                        .buttonStyle(.plain).help("Auto-scroll (A)")
                }
                Button { model.toggleBookmark() } label: { Image(systemName: model.bookmarked ? "bookmark.fill" : "bookmark").font(.system(size: 15.5)) }
                    .buttonStyle(.plain).help("Bookmark chapter (B)")
                Button { model.popover = .settings } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 15.5)) }
                    .buttonStyle(.plain).help("Reader settings")
                    .popover(isPresented: Binding(get: { model.popover == .settings }, set: { if !$0 { model.popover = nil } }), arrowEdge: .bottom) {
                        ReaderSettings(model: model, library: library)
                    }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.system(size: 15.5))
                }
                    .buttonStyle(.plain).help("Full screen (F)")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
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
                    Text("\(Int(scrub.position.rounded()) + 1)").font(.system(size: 12.5, weight: .bold, design: .monospaced))
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

    var rtl: Bool { model.mode == .rightToLeft }
    var previousButton: some View {
        Button { model.goPrevious() } label: { Image(systemName: rtl ? "forward.end" : "backward.end").font(.system(size: 15.5)) }
            .buttonStyle(.plain).disabled(model.previousChapter == nil).opacity(model.previousChapter == nil ? 0.3 : 1).help("Previous chapter ([)")
    }
    var nextButton: some View {
        Button { model.goNext() } label: { Image(systemName: rtl ? "backward.end" : "forward.end").font(.system(size: 15.5)) }
            .buttonStyle(.plain).disabled(model.nextChapter == nil).opacity(model.nextChapter == nil ? 0.3 : 1).help("Next chapter (])")
    }
    var current: some View {
        Text("\(model.index + 1)").font(.system(size: 13.5, weight: .semibold, design: .monospaced))
            .frame(minWidth: 24, alignment: rtl ? .leading : .trailing)
    }
    var total: some View {
        Text("\(model.pages.count)").font(.system(size: 13.5, design: .monospaced)).opacity(0.5)
            .frame(minWidth: 24, alignment: rtl ? .trailing : .leading)
    }

    var body: some View {
        // Right-to-left manga reads from the right: the whole bar is mirrored so the start of the chapter
        // (page 1, previous chapter) sits on the right, under the scrubber's starting end.
        let rtl = model.mode == .rightToLeft
        HStack(spacing: 18) {
            if rtl { nextButton; total } else { previousButton; current }
            if model.pages.count > 1 {
                PageScrubber(model: model, scrub: model.scrub)
            } else { Spacer() }
            if rtl { current; previousButton } else { total; nextButton }
            if abs(model.zoom - 1) > 0.01 {
                Button { model.resetZoom() } label: {
                    Text("\(Int((model.zoom * 100).rounded()))% ✕").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.plain).help("Reset zoom (⌘0)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
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
        let chapters = Array((library.entry(model.series.id)?.ordered ?? []).reversed())
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(chapters) { c in
                        let current = c.chapter.url == model.chapter.url
                        Button { model.jump(to: c.chapter) } label: {
                            HStack(spacing: 12) {
                                Circle().fill(c.read || current ? Color.clear : Theme.ink).frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.chapter.name).font(.system(size: 14.5, weight: current ? .bold : .regular))
                                        .foregroundStyle(c.read && !current ? Theme.dim : Theme.ink).lineLimit(1)
                                    if c.started { Text("Page \(c.lastPage + 1)\(c.pageCount.map { " of \($0)" } ?? "")").font(.system(size: 12.5)).foregroundStyle(Theme.dim) }
                                }
                                Spacer(minLength: 8)
                                if c.bookmarked { Image(systemName: "bookmark.fill").font(.system(size: 12.5)).foregroundStyle(Theme.ink) }
                                if c.downloaded { Image(systemName: "arrow.down.circle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.dim) }
                                if current { Text("READING").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(current ? Theme.ink.opacity(0.07) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                        .id(c.chapter.url)
                    }
                }
            }
            .onAppear { proxy.scrollTo(model.chapter.url, anchor: .center) }
        }
        .frame(width: 340, height: 460)
        .background(Theme.bg)
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
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(width: 420)
        .frame(maxHeight: 560)
        .background(Theme.bg)
    }

    var panel: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack { Eyebrow("Reading settings · this comic"); Spacer() }.padding(.top, 10).padding(.bottom, 2)
                ReadingSettingsPanel(library: library, seriesID: model.series.id, onMode: { model.setMode($0) })
                HStack { TextAction(title: "Keyboard shortcuts") { showShortcuts = true }; Spacer() }.padding(.vertical, 16)
            }
        }
    }

    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { TextAction(title: "← Back") { showShortcuts = false }; Spacer() }.padding(.vertical, 10)
            ForEach([("Space / ↓ ↑", "scroll"), ("[ ]", "previous / next chapter"), ("A", "auto-scroll"), ("+ − 0", "zoom, reset"),
                     ("pinch · double-click", "zoom"), ("C", "chapters"), ("S", "reading settings"), ("B", "bookmark"), ("F", "full screen"), ("M", "show controls"),
                     ("W", "open chapter in WebView"), ("right-click a page", "copy, save, share, WebView, use as cover"), ("Esc", "back")], id: \.0) { k, d in
                HStack(alignment: .firstTextBaseline) {
                    Text(k).font(.system(size: 13.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 12)
                    Text(d).font(.system(size: 13.5)).foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 9).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
    }
}

/// Opt-in (Reader settings › Show page number): just the number, nothing else.
struct PageNumberPill: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        Text("\(model.index + 1) / \(model.pages.count)").font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.black.opacity(0.6), in: Capsule()).foregroundStyle(.white.opacity(0.85))
            .padding(12)
    }
}
