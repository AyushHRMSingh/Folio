import AppKit
import FolioCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var window: NSWindow!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Keep everything inside Folio's data folder: no saved window state, and wipe any
        // preferences AppKit writes on our behalf.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        wipePreferences()
        buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Folio"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.nsBg
        window.isRestorable = false
        let host = NSHostingView(rootView: RootView(app: model))
        host.sizingOptions = []          // the window decides its size, not the content's ideal size
        window.contentView = host
        window.contentMinSize = NSSize(width: 760, height: 520)
        model.window = window
        window.center()
        if ProcessInfo.processInfo.environment["FOLIO_DEBUG"] != nil {
            // Test instance: off-screen, no Dock icon, never steals focus.
            NSApp.setActivationPolicy(.accessory)
            window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            window.orderFront(nil)
            DebugHook.install(app: model, window: window)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Escape = back, everywhere. It never leaves full screen (⌃⌘F or F in the reader does that), and
        // with nothing to go back to it does nothing.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard e.keyCode == 53, let self, let m = self.model,
                      NSApp.keyWindow === self.window, !(self.window.firstResponder is NSText) else { return e }
                if let r = m.reader {
                    if r.popover != nil { r.popover = nil } else { r.close() }
                } else if !m.path.isEmpty {
                    m.path.removeLast()
                } else if let cur = m.sidebar, cur == .extensions || { if case .source = cur { true } else { false } }() {
                    m.sidebar = .sources
                }
                return nil
            }
        }
        // Quit cleanly on SIGTERM so the extension engine is stopped first.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        termSource = src
    }
    private var termSource: DispatchSourceSignal?
    private var escMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.library.save()
        ExtensionEngine.shared.stop()
        wipePreferences()
    }

    private func wipePreferences() {
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        let saved = Paths.home.appendingPathComponent("Library/Saved Application State/\(Bundle.main.bundleIdentifier ?? "x").savedState")
        try? FileManager.default.removeItem(at: saved)
        // With persistence ignored, AppKit parks window state in $TMPDIR (the app's temp folder).
        let tmpState = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "x").savedState")
        try? FileManager.default.removeItem(at: tmpState)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Folio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(goSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Folio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Import Files…", action: #selector(importFiles), keyEquivalent: "o")
        file.addItem(withTitle: "Search All Sources", action: #selector(searchAll), keyEquivalent: "k")
        let upd = file.addItem(withTitle: "Update Library", action: #selector(updateLibrary), keyEquivalent: "r")
        upd.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Find in Library", action: #selector(searchAll), keyEquivalent: "f")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        let fs = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view

        let goItem = NSMenuItem(); main.addItem(goItem)
        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Library", action: #selector(goLibrary), keyEquivalent: "1")
        go.addItem(withTitle: "Recent", action: #selector(goRecent), keyEquivalent: "2")
        go.addItem(withTitle: "Sources", action: #selector(goSources), keyEquivalent: "3")
        go.addItem(withTitle: "Settings", action: #selector(goSettings), keyEquivalent: "4")
        go.addItem(.separator())
        go.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        goItem.submenu = go

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.windowsMenu = win

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts), keyEquivalent: "/")
        helpItem.submenu = help
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    private func go(_ s: SidebarItem) { model.closeReader(); model.sidebar = s; model.path = NavigationPath() }
    @objc func goLibrary() { go(.library) }
    @objc func goRecent() { go(.recents) }
    @objc func goSources() { go(.sources) }
    @objc func goSettings() { go(.settings) }
    @objc func goBack() {
        if model.reader != nil { model.reader?.close() }
        else if !model.path.isEmpty { model.path.removeLast() }
        else if let cur = model.sidebar, cur == .extensions || { if case .source = cur { true } else { false } }() { model.sidebar = .sources }
    }
    @objc func showShortcuts() {
        let a = NSAlert()
        a.messageText = "Keyboard Shortcuts"
        a.informativeText = """
        ⌘1–4  Library, Recent, Sources, Settings
        ⌘,  Settings
        ⌘[  or Esc  Back
        ⌘F / ⌘K  Search
        ⇧⌘R  Update library

        In the reader
        Space / ↓ ↑  scroll
        [ ]  previous / next chapter
        A  auto-scroll    B  bookmark    C  chapters
        F  full screen    M  show controls
        + − 0  zoom, reset
        """
        a.runModal()
    }
    @objc func importFiles() { model.importLocal() }
    @objc func updateLibrary() { model.updateLibrary() }
    @objc func searchAll() {
        model.closeReader()
        model.sidebar = .library
        model.path = NavigationPath()
        model.searchFocus += 1
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
