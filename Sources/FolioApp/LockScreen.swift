import AppKit
import FolioCore
import LocalAuthentication
import SwiftUI

/// Folio's privacy lock. With a PIN set, Folio opens locked and locks again when it has been in the background
/// for the chosen time, when the screen sleeps or locks, or on ⌘L. While locked, nothing but the lock screen is
/// shown, other Folio windows are hidden, and every key goes to the PIN (nothing reaches the reader or the menus).
@MainActor
final class LockModel: ObservableObject {
    @Published private(set) var locked = false
    @Published private(set) var typed = ""
    @Published private(set) var message: String?
    @Published private(set) var shakes = 0
    @Published private(set) var waitUntil: Date?
    @Published private(set) var checking = false

    private let library: Library
    weak var app: AppModel?
    private var keyMonitor: Any?
    private var backgroundSince: Date?
    private var wrong = 0
    /// True while a Touch ID or password prompt is up: it takes focus from Folio, which must not re-lock.
    private var authenticating = false
    /// When the last Touch ID prompt closed: coming back from it must not open another one straight away.
    private var promptClosed = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init(library: Library) {
        self.library = library
        if library.settings.appLock != nil { lock() }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }

    var settings: AppLock? { library.settings.appLock }
    var enabled: Bool { settings != nil }

    static var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
    /// Touch ID–only lock (no PIN).
    var pinless: Bool { settings.map { !$0.usesPIN } ?? false }
    var offersTouchID: Bool { (pinless || (settings?.touchID ?? false)) && Self.touchIDAvailable }

    // MARK: when to lock

    private func wentToBackground() {
        guard enabled, !locked, !authenticating else { return }
        backgroundSince = Date()
        if settings?.after == .immediately { lock() }       // also keeps Folio's content out of Mission Control
    }

    private func cameBack() {
        defer { backgroundSince = nil }
        guard enabled, !authenticating else { return }
        if !locked, let since = backgroundSince, Date().timeIntervalSince(since) >= TimeInterval(settings?.after.rawValue ?? 0) { lock() }
        if locked, offersTouchID, waitUntil == nil, Date().timeIntervalSince(promptClosed) > 2 { touchID() }
    }

    func lock() {
        guard enabled, !locked else { return }
        locked = true
        typed = ""; message = nil
        app?.reader?.autoScroll = false
        for w in NSApp.windows where w !== app?.window && w.isVisible && !(w is NSPanel) { w.orderOut(nil) }
        installKeys()
    }

    private func unlock() {
        locked = false
        typed = ""; message = nil; wrong = 0; waitUntil = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: PIN

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, self.locked else { return e }
                if let p = self.app?.privacy, p.covered { p.uncover(); return nil }    // first key only reveals the lock screen
                let mods = e.modifierFlags.intersection([.command, .control, .option])
                if mods == .command, e.charactersIgnoringModifiers == "q" { return e }     // quitting is always allowed
                if mods.isEmpty { self.key(e) }
                return nil                                   // everything else stops here
            }
        }
    }

    private func key(_ e: NSEvent) {
        switch e.keyCode {
        case 51, 117: if !typed.isEmpty { typed.removeLast() }           // delete
        case 53: typed = ""                                              // esc
        case 36, 76: if pinless { touchID() } else { submit() }         // return
        default:
            guard let c = e.characters, c.count == 1, let ch = c.first, ch.isASCII, ch.isNumber else { return }
            type(String(ch))
        }
    }

    /// One digit (keyboard or the on-screen pad).
    func type(_ d: String) {
        guard locked, !pinless, !checking, typed.count < AppLock.digits.upperBound else { return }
        if let w = waitUntil, w > Date() { return }
        typed += d
        if message == "Wrong PIN" { message = nil }
        if typed.count == settings?.length { submit() }
    }

    func backspace() { if !typed.isEmpty { typed.removeLast() } }

    func submit() {
        guard let s = settings, !typed.isEmpty, !checking else { return }
        let pin = typed
        checking = true
        Task {
            let ok = await Task.detached(priority: .userInitiated) { s.matches(pin) }.value     // slow on purpose
            checking = false
            if ok { unlock(); return }
            wrong += 1
            typed = ""
            withAnimation(.default) { shakes += 1 }
            if wrong >= 5 {
                let secs = min(30 * pow(2, Double(wrong - 5)), 900)
                waitUntil = Date().addingTimeInterval(secs)
                message = nil
                Task {
                    try? await Task.sleep(for: .seconds(secs))
                    if let w = waitUntil, w <= Date() { waitUntil = nil }
                }
            } else {
                message = "Wrong PIN"
            }
        }
    }

    // MARK: Touch ID and "forgot PIN"

    func touchID() {
        guard locked, !authenticating else { return }
        guard offersTouchID else { if pinless { macPassword() }; return }      // no Touch ID right now: the Mac password
        authenticating = true
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""          // the fallback is on Folio's own screen (PIN, or "Use Mac Password")
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock your library") { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                self.promptClosed = Date()
                if ok { self.unlock() }
            }
        }
    }

    /// Touch ID–only lock: the Mac's password (or Touch ID) unlocks too, e.g. with the lid closed.
    func macPassword() {
        guard locked, !authenticating else { return }
        authenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your library") { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                self.promptClosed = Date()
                if ok { self.unlock() }
            }
        }
    }

    /// Turn on the Touch ID–only lock, after one successful touch (so it is known to work).
    func setTouchIDOnly() {
        guard Self.touchIDAvailable, !authenticating else { return }
        authenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "lock Folio with Touch ID") { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                guard ok else { return }
                self.library.settings.appLock = AppLock.touchIDOnly(after: self.settings?.after ?? .immediately)
            }
        }
    }

    /// Prove it's the Mac's owner (Mac password or Touch ID), then the PIN is removed; a new one can be set in Settings.
    func forgot() {
        guard !authenticating else { return }
        authenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "remove Folio\u{2019}s PIN") { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                guard ok else { return }
                self.library.settings.appLock = nil
                self.unlock()
                self.app?.status = "PIN removed. Set a new one in Settings \u{203A} Privacy."
            }
        }
    }

    // MARK: settings

    func setPIN(_ pin: String) -> Bool {
        guard let n = settings?.withPIN(pin) ?? AppLock.make(pin: pin) else { return false }
        library.settings.appLock = n
        return true
    }

    func turnOff() { library.settings.appLock = nil; unlock() }

    /// Dev only (QA harness): type a PIN as if from the keyboard.
    func debugType(_ s: String) { for c in s { type(String(c)) } }
    /// Dev only (QA harness): a Touch ID–only lock without asking for a touch.
    func debugSetTouchIDOnly() { library.settings.appLock = .touchIDOnly() }
}

/// Covers the whole window while locked. Always in the view tree so it can watch the model.
struct LockOverlay: View {
    @ObservedObject var model: LockModel
    var body: some View {
        if model.locked { LockScreen(model: model).transition(.opacity) }
    }
}

private struct LockScreen: View {
    @ObservedObject var model: LockModel
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            FolioMark().frame(width: 104)
            Text(".folio").font(.system(size: 22, weight: .bold, design: .monospaced)).tracking(-0.8).foregroundStyle(Theme.ink)
                .padding(.top, 10)
            if model.pinless {
                Image(systemName: "touchid").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Theme.dim)
                    .padding(.top, 44)
                Text("Folio is locked").font(.system(size: 13.5)).foregroundStyle(Theme.faint)
                    .padding(.top, 16).frame(height: 20)
                HStack(spacing: 14) {
                    if model.offersTouchID {
                        Button { model.touchID() } label: {
                            Label("Unlock with Touch ID", systemImage: "touchid").font(.system(size: 14))
                        }
                        .buttonStyle(.monoPrimary)
                    }
                    TextAction(title: "Use Mac password") { model.macPassword() }
                }
                .padding(.top, 26)
            } else {
                dots.padding(.top, 40)
                    .modifier(Shake(amount: CGFloat(model.shakes)))
                Text(status).font(.system(size: 13.5)).foregroundStyle(model.message == nil && model.waitUntil == nil ? Theme.faint : Theme.dim)
                    .padding(.top, 18).frame(height: 20)
                pad.padding(.top, 26)
                HStack(spacing: 14) {
                    if model.offersTouchID {
                        Button { model.touchID() } label: {
                            Label("Use Touch ID", systemImage: "touchid").font(.system(size: 14))
                        }
                        .buttonStyle(.mono)
                    }
                    TextAction(title: "Forgot PIN?") { model.forgot() }
                }
                .padding(.top, 26)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .contentShape(Rectangle())
        .onTapGesture {}                     // nothing under the lock screen can be clicked
        .onReceive(tick) { now = $0 }
    }

    private var status: String {
        if let w = model.waitUntil, w > now {
            return "Too many tries. Try again in \(Int(w.timeIntervalSince(now).rounded(.up))) s."
        }
        return model.message ?? "Enter your PIN"
    }

    private var dots: some View {
        let n = max(model.settings?.length ?? 4, model.typed.count)
        return HStack(spacing: 16) {
            ForEach(0..<n, id: \.self) { i in
                Circle()
                    .fill(i < model.typed.count ? Theme.ink : .clear)
                    .overlay(Circle().strokeBorder(Theme.dim, lineWidth: 1.2))
                    .frame(width: 13, height: 13)
            }
        }
        .animation(.easeOut(duration: 0.1), value: model.typed.count)
    }

    /// For clicking instead of typing.
    private var pad: some View {
        let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        return VStack(spacing: 12) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { k in
                        if k.isEmpty { Color.clear.frame(width: 64, height: 46) }
                        else { PadKey(label: k) { k == "⌫" ? model.backspace() : model.type(k) } }
                    }
                }
            }
        }
    }
}

private struct PadKey: View {
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Group {
                if label == "⌫" { Image(systemName: "delete.left").font(.system(size: 16)) }
                else { Text(label).font(.system(size: 20, weight: .light, design: .monospaced)) }
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 64, height: 46)
            .background(hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label == "⌫" ? "Delete" : label)
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}

/// Set or change the PIN: type it, then type it again.
struct SetPINSheet: View {
    @ObservedObject var lock: LockModel
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var confirming = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(lock.settings?.usesPIN == true ? "Change PIN" : "Set a PIN")
            Text(confirming ? "Type it again." : "4 to 8 digits.").font(.system(size: 14)).foregroundStyle(Theme.dim)
            MonoField(placeholder: confirming ? "Same PIN again" : "PIN", text: confirming ? $second : $first, secure: true, width: 220)
                .focused($focused)
                .padding(.horizontal, 10).padding(.vertical, 9).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .onSubmit(next)
                .onChange(of: first) { _, v in first = String(v.filter(\.isNumber).prefix(8)) }
                .onChange(of: second) { _, v in second = String(v.filter(\.isNumber).prefix(8)) }
            if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.dim) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.mono).keyboardShortcut(.cancelAction)
                Button(confirming ? "Set PIN" : "Next", action: next).buttonStyle(.monoPrimary)
                    .disabled(!AppLock.isValid(confirming ? second : first))
            }
        }
        .padding(Theme.pad)
        .frame(width: 380)
        .background(Theme.bg)
        .onAppear { focused = true }
    }

    private func next() {
        if !confirming {
            guard AppLock.isValid(first) else { problem = "Use 4 to 8 digits."; return }
            confirming = true; problem = nil; focused = true
            return
        }
        guard second == first else { problem = "The PINs don\u{2019}t match. Start again."; first = ""; second = ""; confirming = false; return }
        if lock.setPIN(first) { dismiss() }
    }
}

/// "Hide when in background": while another app is in front, every Folio window is covered in plain black, so
/// nothing shows in the app switcher, Mission Control, screenshots of the desktop or beside other apps.
/// Coming back to Folio (⌘-Tab, Dock) keeps it black: only a click or a key press in Folio shows it again, and
/// that first click or key does nothing else.
/// It is AppKit, not SwiftUI, so the cover is drawn before macOS takes its snapshot of the window.
@MainActor
final class PrivacyScreen {
    private let library: Library
    private var covers: [(window: NSWindow, view: NSView)] = []
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    /// The QA harness runs Folio in the background on purpose; there it only covers when asked (`privacy:on`).
    private let automatic = ProcessInfo.processInfo.environment["FOLIO_DEBUG"] == nil

    init(library: Library) {
        self.library = library
        let nc = NotificationCenter.default
        for n in [NSApplication.willResignActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.automatic { self.cover() } }
            })
        }
    }

    var covered: Bool { !covers.isEmpty }

    func cover() {
        guard library.settings.privacyScreen else { return }
        for w in NSApp.windows where w.isVisible && !(w is NSPanel) && !covers.contains(where: { $0.window === w }) {
            guard let host = w.contentView?.superview ?? w.contentView else { continue }
            let v = BlackView(frame: host.bounds)
            v.autoresizingMask = [.width, .height]
            host.addSubview(v, positioned: .above, relativeTo: nil)       // above the content and the title bar
            covers.append((w, v))
            w.displayIfNeeded()
        }
        if covered, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, self.covered else { return e }
                    if e.type == .keyDown, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { return e }
                    // A scroll over the black window while another app is in front is not coming back to Folio.
                    if e.type == .scrollWheel && !NSApp.isActive { return nil }
                    self.uncover()
                    return nil                           // the interaction that reveals Folio does nothing else
                }
            }
        }
    }

    func uncover() {
        for c in covers { c.view.removeFromSuperview() }
        covers = []
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private final class BlackView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { nil }
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) { NSColor.black.setFill(); dirtyRect.fill() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
        override func mouseDown(with event: NSEvent) {}          // clicks never reach what's underneath
        override func rightMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
    }
}
