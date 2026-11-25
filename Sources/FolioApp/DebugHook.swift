import AppKit
import FolioCore
import SwiftUI

/// Development-only remote control, used to drive and snapshot Folio for testing.
/// Inactive unless Folio is launched with FOLIO_DEBUG=<token>; it then listens only for
/// distributed notifications named "local.folio.debug.<token>". Snapshots render Folio's own
/// window (no screen-recording permission involved).
@MainActor
enum DebugHook {
    static var observer: NSObjectProtocol?
    static let enabled = ProcessInfo.processInfo.environment["FOLIO_DEBUG"] != nil
    /// Simulated network latency for page images (seconds, random up to this), debug only.
    static let delay = Double(ProcessInfo.processInfo.environment["FOLIO_DEBUG_DELAY"] ?? "") ?? 0

    static func install(app: AppModel, window: NSWindow) {
        guard let token = ProcessInfo.processInfo.environment["FOLIO_DEBUG"], !token.isEmpty else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("local.folio.debug.\(token)"), object: nil, queue: .main) { n in
            let cmd = (n.object as? String) ?? ""
            MainActor.assumeIsolated { handle(cmd, app: app, window: window) }
        }
    }

    static func log(_ s: String) {
        guard let dir = ProcessInfo.processInfo.environment["FOLIO_DEBUG_LOG"] else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = FileHandle(forWritingAtPath: dir) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: dir, atomically: true, encoding: .utf8) }
    }

    static func handle(_ cmd: String, app: AppModel, window: NSWindow) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "snap": snapshot(window, to: arg)
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { window.setContentSize(NSSize(width: wh[0], height: wh[1])); window.center() }
        case "migrate": app.migrating = app.library.entries.first { $0.series.title == arg }
        case "filters": app.debugFilterPanel = (arg == "open")
        case "sidebar":
            switch arg {
            case "search": app.sidebar = .search
            case "library": app.sidebar = .library
            case "recents": app.sidebar = .recents
            case "sources": app.sidebar = .sources
            case "extensions": app.sidebar = .extensions
            case "settings": app.sidebar = .settings
            default: app.sidebar = .source(arg)
            }
        case "read":   // read:<title substring>  (library entry)
            if let e = app.library.entries.first(where: { $0.series.title.localizedCaseInsensitiveContains(arg) }) { app.resume(e) }
            else { log("read: no library entry matching \(arg)") }
        case "open-local":   // open-local:<folder> → add the local series and start reading
            Task {
                let s = Series(sourceID: "local", url: URL(fileURLWithPath: arg).lastPathComponent, title: URL(fileURLWithPath: arg).lastPathComponent)
                do { let e = try await app.library.add(s); app.resume(e) } catch { log("open-local failed: \(error)") }
            }
        case "series":   // series:<title substring> → push its details page
            if let e = app.library.entries.first(where: { $0.series.title.localizedCaseInsensitiveContains(arg) }) {
                app.path.append(e.series)
            }
        case "back": if !app.path.isEmpty { app.path.removeLast() }
        case "settings":       // settings:<page> → open a Settings page (appearance, library, reader, updates, …)
            app.sidebar = .settings
            if let p = SettingsPage(rawValue: arg) { DispatchQueue.main.async { app.path = NavigationPath([p]) } }
        case "add-local":      // add-local:<folder in Local, name or path> → add to library without reading
            Task { _ = try? await app.library.add(Series(sourceID: "local", url: URL(fileURLWithPath: arg).lastPathComponent, title: URL(fileURLWithPath: arg).lastPathComponent)) }
        case "cat-new": _ = app.library.addCategory(arg)
        case "cat-set":        // cat-set:<series substring>|<category name>
            let p = arg.split(separator: "|").map(String.init)
            if p.count == 2, let e = app.library.entries.first(where: { $0.series.title.localizedCaseInsensitiveContains(p[0]) }),
               let c = app.library.settings.categories.first(where: { $0.name == p[1] }) {
                app.library.setCategories(e.id, (e.categoryIDs ?? []) + [c.id])
            }
        case "set":            // set:display=list | set:sort=title | set:filter=unread | set:incognito=on
            let p = arg.split(separator: "=").map(String.init)
            guard p.count == 2 else { break }
            switch p[0] {
            case "display": if let d = LibraryDisplay(rawValue: p[1]) { app.library.settings.libraryDisplay = d }
            case "sort": if let d = LibrarySort(rawValue: p[1]) { app.library.settings.librarySort = d }
            case "filter": app.library.settings.filters = LibraryFilters(); if p[1] == "unread" { app.library.settings.filters.unread = true }
            case "hidesaved": app.library.settings.hideSavedInBrowse = p[1] == "on"
            case "notice": app.library.settings.extensionsNoticeAccepted = p[1] == "on" ? Date() : nil
            case "incognito": app.library.settings.incognito = p[1] == "on"
            case "pin":
                if p[1] == "off" { app.lock.turnOff() }
                else if p[1] == "touchid" { app.lock.debugSetTouchIDOnly() }
                else { _ = app.lock.setPIN(p[1]); app.library.settings.appLock?.touchID = false }
            case "privacy": app.library.settings.privacyScreen = p[1] == "on"
            case "mode": if let m = ReadingMode(rawValue: p[1]) { app.library.settings.defaultMode = m }
            default: break
            }
        case "gsearch":        // gsearch:<query>
            app.sidebar = .search; app.search.query = arg; app.search.run(arg, library: app.library)
        case "close": app.reader?.close()
        case "privacy": if arg == "on" { app.privacy.cover() } else { app.privacy.uncover() }   // privacy:on|off → as if Folio went to the background / came back
        case "setup": app.library.settings.setupDone = arg != "show"       // setup:show|done → first-launch setup on/off
        case "setup-step": NotificationCenter.default.post(name: .folioSetupStep, object: Int(arg))   // setup-step:<0-3>
        case "lock": app.lock.lock()                    // lock → the lock screen (needs set:pin=<digits>)
        case "type-pin": app.lock.debugType(arg)        // type-pin:<digits> → as if typed on the lock screen
        case "web": app.openWeb(arg, title: "QA")       // web:<url> → the in-app web window
        case "blacklist":      // blacklist:<title substring> → blacklist a library series
            if let e = app.library.entries.first(where: { $0.series.title.localizedCaseInsensitiveContains(arg) }) { app.library.blacklist(e.series) }
        case "repo-add":       // repo-add:<index url> → add an extension repo and list what it offers
            Task {
                do {
                    let r = try await ExtensionEngine.shared.addRepo(arg)
                    log("repo added name=\(r.name) index=\(r.indexURL)")
                    let all = try await ExtensionEngine.shared.refreshExtensions()
                    log("repo extensions=\(all.count) e.g. \(all.prefix(3).map(\.name))")
                } catch { log("repo-add failed: \(error)") }
            }
        case "cmd":
            guard let r = app.reader else { return }
            let a = arg.split(separator: ":").map(String.init)
            switch a.first ?? "" {
            case "viewport": r.scroll(.byViewport(CGFloat(Double(a.last ?? "0.85") ?? 0.85)))
            case "points": r.scroll(.byPoints(CGFloat(Double(a.last ?? "200") ?? 200)))
            case "zoomin": r.zoomIn()
            case "zoomout": r.zoomOut()
            case "zoomreset": r.resetZoom()
            case "next": r.goNext()
            case "prev": r.goPrevious()
            case "page": r.setIndex(Int(a.last ?? "0") ?? 0)
            case "anchor": log("anchor \(String(describing: a))")
            case "mode": if let m = ReadingMode(rawValue: a.last ?? "") { r.setMode(m) }
            case "controls": r.controls = (a.last == "on"); if r.controls { r.poke() }
            case "popover": r.popover = a.last == "chapters" ? .chapters : a.last == "settings" ? .settings : nil
            case "autoscroll": r.autoScroll = (a.last == "on")
            case "double": app.library.setReaderPref(r.series.id, \.doublePage, \.doublePage, a.last == "on")
            case "split": app.library.setReaderPref(r.series.id, \.splitWidePages, \.splitWidePages, a.last == "on")
            case "crop": app.library.setReaderPref(r.series.id, \.cropBorders, \.cropBorders, a.last == "on")
            case "width": if let w = Double(a.last ?? "") { app.library.setReaderPref(r.series.id, \.webtoonWidth, \.webtoonWidth, w) }
            default: break
            }
        case "state":
            log("cloudflare solver=\(CloudflareSolver.shared.url ?? "-") engine flareSolverr=\(ExtensionEngine.shared.flareSolverrURL)")
            log("window frame=\(window.frame) min=\(window.minSize) contentMax=\(window.contentMaxSize) contentMin=\(window.contentMinSize)")
            if let r = app.reader {
                log("reader chapter=\(r.chapter.name) index=\(r.index)/\(r.pages.count) zoom=\(r.zoom) items=\(r.items.count) loading=\(r.loading) error=\(r.error ?? "-")")
            } else {
                log("no reader; sidebar=\(String(describing: app.sidebar)); library=\(app.library.entries.count)")
            }
        case "fullscreen":     // fullscreen:on|off (only toggles when state differs)
            let isFull = window.styleMask.contains(.fullScreen)
            if (arg == "on") != isFull { window.collectionBehavior.insert(.fullScreenPrimary); window.toggleFullScreen(nil) }
            log("fullscreen requested=\(arg) wasFull=\(isFull)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { log("fullscreen now=\(window.styleMask.contains(.fullScreen)) frame=\(window.frame)") }
        case "key": sendKey(arg, window: window)
        case "popover-dump": popoverDump(main: window)
        case "snap-popover":
            if let w = extraWindows(main: window).first { snapshot(w, to: arg) } else { log("snap-popover: no popover window") }
        case "hover":          // hover:<x>,<y> (window point from top-left)
            let c = arg.split(separator: ",").compactMap { Double($0) }
            guard c.count == 2, let cv = window.contentView else { log("hover: bad args"); break }
            let h = cv.bounds.height
            let p = NSPoint(x: c[0], y: cv.isFlipped ? c[1] : h - c[1])
            let wp = cv.convert(p, to: nil)
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(e)
                if let v = cv.hitTest(cv.convert(wp, from: nil)) { v.mouseMoved(with: e) }
                log("hover \(c[0]),\(c[1]) -> window \(wp)")
            }
        case "quit": NSApp.terminate(nil)
        default: log("unknown command \(cmd)")
        }
    }

    /// Captures the window exactly as the window server composited it (Folio's own window only).
    static func snapshot(_ window: NSWindow, to path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { log("snap: capture unavailable"); return }
        let f = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 1<<3, kCGWindowImageBoundsIgnoreFraming = 1<<0 | BestResolution 1<<3
        guard let img = f(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            log("snap: capture failed"); return
        }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("snap \(path) \(img.width)x\(img.height)")
    }
}

extension DebugHook {
    static let keyCodes: [String: UInt16] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,
        "i":34,"p":35,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"`":50,
        "return":36,"tab":48,"space":49,"delete":51,"esc":53,"left":123,"right":124,"down":125,"up":126,
    ]

    /// key:<spec> e.g. esc, space, s, ], cmd+[, cmd+shift+k
    static func sendKey(_ spec: String, window: NSWindow) {
        var mods: NSEvent.ModifierFlags = []
        var name = spec
        // modifiers are everything before the last "+" (a bare "+" key is not supported)
        if let i = spec.lastIndex(of: "+"), i != spec.startIndex {
            for m in spec[..<i].split(separator: "+") {
                switch m.lowercased() {
                case "cmd", "command": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt", "alt", "option": mods.insert(.option)
                case "ctrl", "control": mods.insert(.control)
                default: break
                }
            }
            name = String(spec[spec.index(after: i)...])
        }
        name = name.lowercased()
        guard let code = keyCodes[name] else { log("key: unknown key \(spec)"); return }
        let chars: String
        switch name {
        case "esc": chars = "\u{1b}"
        case "space": chars = " "
        case "return": chars = "\r"
        case "tab": chars = "\t"
        case "delete": chars = "\u{7f}"
        case "left": chars = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": chars = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up": chars = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": chars = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: chars = mods.contains(.shift) ? name.uppercased() : name
        }
        // Prefer the key window (a popover or sheet may hold focus), else the main window.
        let target = NSApp.keyWindow ?? window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: target.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: name.count == 1 ? name : chars, isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(e)
        }
        log("key \(spec) code=\(code) mods=\(mods.rawValue) -> \(type(of: target)) #\(target.windowNumber) firstResponder=\(String(describing: target.firstResponder.map { type(of: $0) }))")
    }

    static func extraWindows(main: NSWindow) -> [NSWindow] {
        NSApp.windows.filter { $0 !== main && $0.isVisible && $0.frame.width > 1 }
    }

    static func popoverDump(main: NSWindow) {
        let ws = extraWindows(main: main)
        if ws.isEmpty { log("popover-dump: no extra windows (main child windows: \(main.childWindows?.count ?? 0), attachedSheet: \(main.attachedSheet != nil))") }
        for w in ws {
            var lines: [String] = []
            if let v = w.contentView { flatten(v, into: &lines, depth: 0) }
            log("popover-dump window \(type(of: w)) frame=\(w.frame) key=\(w.isKeyWindow) title=\(w.title)\n" + Array(NSOrderedSet(array: lines)).map { "\($0)" }.joined(separator: "\n"))
        }
        if let sh = main.attachedSheet, !ws.contains(sh) {
            var lines: [String] = []
            if let v = sh.contentView { flatten(v, into: &lines, depth: 0) }
            log("popover-dump sheet \(type(of: sh)) frame=\(sh.frame)\n" + lines.joined(separator: "\n"))
        }
    }

    private static func flatten(_ v: NSView, into out: inout [String], depth: Int) {
        var bits: [String] = []
        if let t = v as? NSTextField { bits.append("text=\"\(t.stringValue)\"") }
        if let b = v as? NSButton, !b.title.isEmpty { bits.append("button=\"\(b.title)\"") }
        if let l = v.accessibilityLabel(), !l.isEmpty { bits.append("label=\"\(l)\"") }
        if let val = v.accessibilityValue() { bits.append("value=\"\(val)\"") }
        if let t = v.accessibilityTitle(), !t.isEmpty { bits.append("title=\"\(t)\"") }
        let role = v.accessibilityRole()?.rawValue ?? ""
        if !bits.isEmpty || depth < 2 { out.append(String(repeating: " ", count: depth) + "\(type(of: v)) \(role) " + bits.joined(separator: " ")) }
        for sub in v.subviews { flatten(sub, into: &out, depth: depth + 1) }
        // SwiftUI exposes its content through the accessibility tree rather than subviews.
        if let kids = v.accessibilityChildren() as? [AnyObject], depth > 0 {
            for k in kids { flattenAX(k, into: &out, depth: depth + 1) }
        }
    }

    private static func flattenAX(_ el: AnyObject, into out: inout [String], depth: Int) {
        guard depth < 14, let e = el as? NSAccessibilityElementProtocol & NSObjectProtocol else { return }
        var bits: [String] = []
        let o = el as AnyObject
        func str(_ sel: String) -> String? { o.responds(to: Selector(sel)) ? (o.perform(Selector(sel))?.takeUnretainedValue() as? String) : nil }
        if let l = str("accessibilityLabel"), !l.isEmpty { bits.append("label=\"\(l)\"") }
        if let t = str("accessibilityTitle"), !t.isEmpty { bits.append("title=\"\(t)\"") }
        if let v = o.perform(Selector("accessibilityValue"))?.takeUnretainedValue() { bits.append("value=\"\(v)\"") }
        let role = str("accessibilityRole") ?? ""
        if !bits.isEmpty { out.append(String(repeating: " ", count: depth) + "AX \(role) " + bits.joined(separator: " ")) }
        _ = e
        if let kids = o.perform(Selector("accessibilityChildren"))?.takeUnretainedValue() as? [AnyObject] {
            for k in kids { flattenAX(k, into: &out, depth: depth + 1) }
        }
    }

    /// Stand-in filters shaped like a real extension's, for looking at the panel without the engine.
    static var demoFilters: [SourceFilter] {
        func tri(_ n: String, _ s: SourceFilter.TriState = .ignore) -> SourceFilter { SourceFilter(name: n, kind: .tristate(s)) }
        return [
            SourceFilter(name: "Sort by", kind: .sort(values: ["Latest", "Popular", "Rating"], index: 1, ascending: false)),
            SourceFilter(name: "Status", kind: .select(values: ["Any", "Ongoing", "Completed"], index: 0)),
            SourceFilter(name: "Author", kind: .text("")),
            SourceFilter(name: "Only translated", kind: .checkbox(false)),
            SourceFilter(name: "Genres", kind: .group(["Action", "Comedy", "Drama", "Fantasy", "Horror", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Thriller", "Isekai", "Mystery"].enumerated().map { tri($1, $0 == 1 ? .include : ($0 == 4 ? .exclude : .ignore)) })),
        ]
    }
}
