import AppKit
import Combine
import FolioCore
import SwiftUI

// MARK: - View

extension ReaderBackground {
    var color: Color {
        switch self { case .black: .black; case .gray: Color(white: 0.16); case .white: Color(white: 0.97); case .auto: Color(white: 0.055) }
    }
    var ink: Color { self == .white ? .black : Color.white }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var library: Library
    @FocusState private var focused: Bool
    @State private var fullscreen = false

    init(model: ReaderModel) { self.model = model; self.library = model.app.library }

    var bg: ReaderBackground { model.prefs.readerBackground }

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
                    Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 15).padding(.vertical, 9)
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
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(bg.ink)
                Text(model.chapter.name).font(.callout).foregroundStyle(bg.ink.opacity(0.6))
            }
        } else if let e = model.error {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 38))
                Text(e).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button("Back") { model.close() }.buttonStyle(.mono)
                    Button("Retry") { model.retry() }.buttonStyle(.monoPrimary)
                }
            }
            .foregroundStyle(bg.ink)
        } else if let source = model.source {
            let st = model.prefs
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
            case "w": model.openInWeb()
            case "c": model.popover = model.popover == .chapters ? nil : .chapters
            case "s": model.popover = model.popover == .settings ? nil : .settings
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

