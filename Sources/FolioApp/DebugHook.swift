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
                let s = Series(sourceID: "local", url: arg, title: URL(fileURLWithPath: arg).lastPathComponent)
                do { let e = try await app.library.add(s); app.resume(e) } catch { log("open-local failed: \(error)") }
            }
        case "series":   // series:<title substring> → push its details page
            if let e = app.library.entries.first(where: { $0.series.title.localizedCaseInsensitiveContains(arg) }) {
                app.path.append(e.series)
            }
        case "back": if !app.path.isEmpty { app.path.removeLast() }
        case "add-local":      // add-local:<folder> → add to library without reading
            Task { _ = try? await app.library.add(Series(sourceID: "local", url: arg, title: URL(fileURLWithPath: arg).lastPathComponent)) }
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
            case "incognito": app.library.settings.incognito = p[1] == "on"
            default: break
            }
        case "gsearch":        // gsearch:<query>
            app.sidebar = .search; app.search.query = arg; app.search.run(arg, library: app.library)
        case "close": app.reader?.close()
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
            case "double": app.library.settings.doublePage = (a.last == "on")
            case "split": app.library.settings.splitWidePages = (a.last == "on")
            case "crop": app.library.settings.cropBorders = (a.last == "on")
            case "width": if let w = Double(a.last ?? "") { app.library.settings.webtoonWidth = w }
            default: break
            }
        case "state":
            log("window frame=\(window.frame) min=\(window.minSize) contentMax=\(window.contentMaxSize) contentMin=\(window.contentMinSize)")
            if let r = app.reader {
                log("reader chapter=\(r.chapter.name) index=\(r.index)/\(r.pages.count) zoom=\(r.zoom) items=\(r.items.count) loading=\(r.loading) error=\(r.error ?? "-")")
            } else {
                log("no reader; sidebar=\(String(describing: app.sidebar)); library=\(app.library.entries.count)")
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
