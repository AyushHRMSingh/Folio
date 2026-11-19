import AppKit
import FolioCore
import SwiftUI

/// Settings (D1): a short list of sections; each opens its own page on the navigation stack.
enum SettingsPage: String, CaseIterable, Hashable, Identifiable {
    case appearance, library, reader, updates, downloads, privacy, sources, storage, backup, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .library: "Library"
        case .reader: "Reader defaults"
        case .updates: "Updates"
        case .downloads: "Downloads"
        case .privacy: "Privacy"
        case .sources: "Sources & extensions"
        case .storage: "Storage"
        case .backup: "Backup & import"
        case .about: "About"
        }
    }
    var icon: String {
        switch self {
        case .appearance: "circle.lefthalf.filled"
        case .library: "books.vertical"
        case .reader: "book"
        case .updates: "arrow.clockwise"
        case .downloads: "arrow.down.circle"
        case .privacy: "eye.slash"
        case .sources: "square.stack.3d.up"
        case .storage: "internaldrive"
        case .backup: "externaldrive"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(.system(size: 36, weight: .light)).tracking(-1).foregroundStyle(Theme.ink)
                    .padding(.top, 8).padding(.bottom, 18)
                ForEach(SettingsPage.allCases) { p in
                    NavigationLink(value: p) { SettingsRootRow(page: p, summary: summary(p)) }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pad).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }

    /// One line saying what each section is set to now.
    func summary(_ p: SettingsPage) -> String {
        let s = library.settings
        switch p {
        case .appearance: return s.appearance.label
        case .library: return s.categories.isEmpty ? "No categories" : "\(s.categories.count) categor\(s.categories.count == 1 ? "y" : "ies")"
        case .reader:
            return s.defaultMode.shortLabel + (s.defaultMode == .webtoon ? " · width \(Int(s.webtoonWidth * 100))%" : "")
        case .updates:
            return s.updateInterval == .off ? "Only when you ask" : "Check: " + s.updateInterval.label
        case .downloads:
            return "\(s.parallelDownloads) at a time" + (s.deleteAfterRead ? " · delete after reading" : "")
        case .privacy: return s.incognito ? "Incognito is on" : "Incognito is off"
        case .sources:
            let n = s.servers.count
            return (n == 0 ? "No OPDS servers" : "\(n) OPDS server\(n == 1 ? "" : "s")")
                + (s.extensionsNoticeAccepted == nil ? " · extensions not set up" : "")
        case .storage: return "Downloads, cache, data folder"
        case .backup: return s.autoBackup ? "Daily backup is on" : "Daily backup is off"
        case .about: return "Folio \(SettingsAbout.version)"
        }
    }
}

struct SettingsRootRow: View {
    let page: SettingsPage
    let summary: String
    @State private var hover = false
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: page.icon).font(.system(size: 15.5)).foregroundStyle(Theme.dim).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                Text(summary).font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(hover ? Theme.ink : Theme.faint)
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .background(hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 8) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// The page that a Settings row opens.
struct SettingsPageView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    let page: SettingsPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackLink(title: "Settings") { if !app.path.isEmpty { app.path.removeLast() } }
                Text(page.title).font(.system(size: 32, weight: .light)).tracking(-0.8).foregroundStyle(Theme.ink).padding(.top, 4)
                content.padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pad).padding(.top, 8).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
    }

    @ViewBuilder var content: some View {
        switch page {
        case .appearance:
            SetRow(label: "Theme") { MonoChoice(options: AppearanceMode.allCases.map { ($0, $0.label.lowercased()) }, selection: $library.settings.appearance) }
        case .library: SettingsLibrary(library: library)
        case .reader:
            ReadingSettingsPanel(library: library, seriesID: nil)
            SetRow(label: "Pages decoded ahead", hint: "Pages ready to show ahead of where you are.") {
                MonoStep(value: $library.settings.preloadPages, range: 1...10)
            }
            Text("Each comic can have its own settings: open a comic and press S, or use \u{201C}Reading Settings\u{2026}\u{201D} on its page.")
                .font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 14)
        case .updates: SettingsUpdates(library: library)
        case .downloads:
            SetRow(label: "Chapters downloaded at a time") { MonoStep(value: $library.settings.parallelDownloads, range: 1...5) }
            SetRow(label: "Delete downloads after reading", hint: "Bookmarked chapters are kept.") { MonoSwitch(isOn: $library.settings.deleteAfterRead) }
        case .privacy: SettingsPrivacy(app: app, library: library)
        case .sources: SettingsSources(app: app, library: library)
        case .storage: SettingsStorage(app: app, library: library)
        case .backup: SettingsBackup(app: app, library: library)
        case .about: SettingsAbout()
        }
    }
}

// MARK: - Pages

struct SettingsLibrary: View {
    @ObservedObject var library: Library
    @State private var showCategories = false
    var body: some View {
        VStack(spacing: 0) {
            SetRow(label: "Categories", hint: library.settings.categories.isEmpty ? "None yet" : library.settings.categories.map(\.name).joined(separator: ", ")) {
                TextAction(title: "Edit…") { showCategories = true }
            }
            SetRow(label: "Leave saved series out of Browse") {
                MonoSwitch(isOn: $library.settings.hideSavedInBrowse)
            }
            SetSection(title: "Blacklist") {
                if library.settings.blacklist.isEmpty {
                    Text("Nothing blacklisted. To hide a series everywhere, use Blacklist\u{2026} in its \u{00B7}\u{00B7}\u{00B7} menu or right-click its cover in Browse.")
                        .font(.system(size: 13)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
                ForEach(library.settings.blacklist.sorted { $0.added > $1.added }) { b in
                    SetRow(label: b.title, hint: "\(library.source(b.sourceID)?.name ?? "Unknown source") \u{00B7} hidden \(b.added.formatted(date: .abbreviated, time: .omitted))") {
                        TextAction(title: "Remove") { library.unblacklist(b.id) }
                    }
                }
            }
            Text("Layout, cover size, columns and counters are in the library\u{2019}s View menu.")
                .font(.system(size: 13)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
        }
        .sheet(isPresented: $showCategories) { CategoriesSheet(library: library) }
    }
}

struct SettingsUpdates: View {
    @ObservedObject var library: Library
    var body: some View {
        VStack(spacing: 0) {
            SetRow(label: "Check for new chapters", hint: hint) {
                Menu {
                    ForEach(UpdateInterval.allCases) { i in
                        Button { library.settings.updateInterval = i } label: {
                            if i == library.settings.updateInterval { Label(i.label, systemImage: "checkmark") } else { Text(i.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) { Text(library.settings.updateInterval.label).font(.system(size: 14)); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                        .foregroundStyle(Theme.dim).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if library.settings.updateInterval != .off {
                SetRow(label: "Skip completed series") { MonoSwitch(isOn: $library.settings.updateRules.skipCompleted) }
                SetRow(label: "Skip series with unread chapters") { MonoSwitch(isOn: $library.settings.updateRules.skipWithUnread) }
                SetRow(label: "Skip series you haven\u{2019}t started") { MonoSwitch(isOn: $library.settings.updateRules.skipNotStarted) }
                if !library.settings.categories.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Skip categories").font(.system(size: 14.5)).foregroundStyle(Theme.ink)
                        FlowLayout(spacing: 6) {
                            ForEach(library.settings.categories) { c in
                                let on = library.settings.updateRules.excludedCategories.contains(c.id)
                                Button {
                                    if on { library.settings.updateRules.excludedCategories.removeAll { $0 == c.id } }
                                    else { library.settings.updateRules.excludedCategories.append(c.id) }
                                } label: {
                                    Text(c.name).font(.system(size: 13.5)).foregroundStyle(on ? Theme.onInk : Theme.dim)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(on ? Theme.ink : Color.clear, in: Capsule())
                                        .overlay { if !on { Capsule().strokeBorder(Theme.line) } }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
    }

    var hint: String {
        let i = library.settings.updateInterval
        guard i != .off else { return "Use the update button in the library when you want to check." }
        let last = library.settings.lastAutoUpdate.map { "Last checked " + $0.formatted(date: .abbreviated, time: .shortened) + ". " } ?? ""
        return last + "These rules apply to automatic checks. The library\u{2019}s update button checks everything."
    }
}

struct SettingsPrivacy: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var confirmHistory = false
    @State private var confirmWeb = false
    var body: some View {
        VStack(spacing: 0) {
            SetRow(label: "Incognito", hint: "While on, Folio doesn't save reading progress or history.") { MonoSwitch(isOn: $library.settings.incognito) }
            SetRow(label: "Reading history", hint: "Empties the Recent list. Reading progress on chapters is kept.") {
                TextAction(title: "Clear…") { confirmHistory = true }
            }
            SetRow(label: "Website data (WebView)", hint: "Logins and site checks you\u{2019}ve passed in Folio\u{2019}s web view.") {
                TextAction(title: "Clear…") { confirmWeb = true }
            }
        }
        .confirmationDialog("Clear website data?", isPresented: $confirmWeb, titleVisibility: .visible) {
            Button("Clear Website Data", role: .destructive) {
                Task { await WebStore.clear(); app.status = "Website data cleared." }
            }
        } message: { Text("You\u{2019}ll be signed out of sites opened in Folio\u{2019}s web view, and passed site checks are forgotten. This can\u{2019}t be undone.") }
        .confirmationDialog("Clear reading history?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) { library.clearHistory(); app.status = "History cleared." }
        } message: { Text("Your Recent list will be emptied. Reading progress on chapters is kept.") }
    }
}

struct SettingsSources: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var flareURL = ""
    @State private var addingServer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetSection(title: "Extensions") {
                NoticePoints().padding(.vertical, 13)
                SetRow(label: "Notice", hint: library.settings.extensionsNoticeAccepted.map {
                    "Accepted " + $0.formatted(date: .abbreviated, time: .omitted)
                } ?? "Not accepted yet. You\u{2019}ll be asked before adding extensions.") {
                    TextAction(title: "Open Extensions") { app.sidebar = .extensions }
                }
                SetRow(label: "Cloudflare checks",
                       hint: "When a site asks you to prove you\u{2019}re human, Folio opens the check in a small window for you to complete. To use an external FlareSolverr instead, enter its address and press Return. This restarts the engine.") {
                    MonoField(placeholder: "http://127.0.0.1:8191/v1", text: $flareURL, width: 240)
                        .padding(.horizontal, 8).padding(.vertical, 6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .onSubmit { applyFlare() }
                }
            }
            SetSection(title: "OPDS servers") {
                ForEach(library.settings.servers) { sv in
                    SetRow(label: sv.name, hint: sv.url) {
                        TextAction(title: "Remove") { library.settings.servers.removeAll { $0.id == sv.id } }
                    }
                }
                if library.settings.servers.isEmpty {
                    Text("Read from your own Komga, Kavita or Calibre-Web server.").font(.system(size: 13.5)).foregroundStyle(Theme.faint).padding(.vertical, 13)
                }
                HStack { TextAction(title: "Add server…") { addingServer = true }; Spacer() }.padding(.top, 12)
            }
        }
        .task { flareURL = library.settings.flareSolverrURL }
        .sheet(isPresented: $addingServer) { AddServerSheet(app: app, library: library) }
    }

    func applyFlare() {
        let u = flareURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u != library.settings.flareSolverrURL else { return }
        library.settings.flareSolverrURL = u
        app.configureCloudflare()
        app.status = u.isEmpty ? "Using Folio\u{2019}s own Cloudflare check window." : "External FlareSolverr saved."
        Task.detached { ExtensionEngine.shared.stop() }     // next use starts it with the new setting
    }
}

struct AddServerSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var testing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Add OPDS server")
            SetRow(label: "Name") { MonoField(placeholder: "My Komga", text: $name) }
            SetRow(label: "Catalog URL") { MonoField(placeholder: "https://komga.example.com/opds/v1.2/catalog", text: $url) }
            SetRow(label: "Username") { MonoField(placeholder: "", text: $user) }
            SetRow(label: "Password") { MonoField(placeholder: "", text: $pass, secure: true) }
            HStack(spacing: 15) {
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.buttonStyle(.mono)
                Button("Test & add") { Task { if await add() { dismiss() } } }
                    .buttonStyle(.monoPrimary).disabled(url.isEmpty || testing)
            }
            .padding(.top, 16)
        }
        .padding(Theme.pad).frame(width: 520).background(Theme.bg)
    }

    func add() async -> Bool {
        testing = true
        defer { testing = false }
        let s = OPDSServer(name: name.isEmpty ? (URL(string: url)?.host ?? "Server") : name,
                           url: url.trimmingCharacters(in: .whitespaces), username: user, password: pass)
        do {
            let r = try await OPDSSource(s).popular(page: 1)
            library.settings.servers.append(s)
            app.status = "Connected to \(s.name) (\(r.series.count) items)."
            return true
        } catch { app.report(error); return false }
    }
}

struct SettingsStorage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var usage: Library.StorageUsage?
    @State private var confirmDownloads = false
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    var body: some View {
        VStack(spacing: 0) {
            SetRow(label: "Downloaded chapters", hint: usage.map { Self.bytes($0.downloads) } ?? "…") {
                TextAction(title: "Delete all…", disabled: (usage?.downloads ?? 0) == 0) { confirmDownloads = true }
            }
            SetRow(label: "Cache", hint: (usage.map { Self.bytes($0.cache) } ?? "…") + " of covers and pages") {
                TextAction(title: "Clear", disabled: (usage?.cache ?? 0) == 0) { library.clearCache(); Task { await refresh() }; app.status = "Cache cleared." }
            }
            SetRow(label: "Data folder") {
                HStack(spacing: 12) {
                    Text(Paths.root.path).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.faint)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled).frame(maxWidth: 300, alignment: .trailing)
                    TextAction(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
                }
            }
        }
        .task { await refresh() }
        .confirmationDialog("Delete every downloaded chapter?", isPresented: $confirmDownloads, titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) { library.clearAllDownloads(); Task { await refresh() } }
        } message: { Text("You can download them again later. This can't be undone.") }
    }

    func refresh() async {
        let d = await Task.detached { Library.size(of: Paths.downloads) }.value
        let c = await Task.detached { Library.size(of: Paths.cache) + ExtensionEngine.cacheSize() }.value
        usage = .init(downloads: d, cache: c)
    }
}

struct SettingsBackup: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var pendingRestore: (data: Data, name: String)?
    @State private var importNote: String?
    @State private var importing = false
    var body: some View {
        VStack(spacing: 0) {
            SetRow(label: "Back up now", hint: "Library, reading progress, categories, settings and picked covers. Downloads aren\u{2019}t included.") {
                TextAction(title: "Save to file…") { saveBackup() }
            }
            SetRow(label: "Restore", hint: "Replaces your library with a Folio backup.") {
                TextAction(title: "Choose file…") { chooseRestore() }
            }
            SetRow(label: "Import from Tachiyomi, Mihon or Tachimanga",
                   hint: importNote ?? "A .tmb, .tachibk or .proto.gz backup. Adds its library; needs the extension engine, and each source\u{2019}s extension must be installed to read.") {
                HStack(spacing: 12) {
                    if importing { ProgressView().controlSize(.small) }
                    TextAction(title: "Import…", disabled: importing) { chooseImport() }
                }
            }
            SetRow(label: "Automatic backup", hint: autoBackupHint) { MonoSwitch(isOn: $library.settings.autoBackup) }
            if library.settings.autoBackup {
                SetRow(label: "Keep the last") { MonoStep(value: $library.settings.backupsKept, range: 1...20) }
                SetRow(label: "Backups folder") { TextAction(title: "Show in Finder") { NSWorkspace.shared.open(Paths.backups) } }
            }
        }
        .confirmationDialog("Replace your library with this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Replace Library", role: .destructive) {
                guard let r = pendingRestore else { return }
                do { let n = try library.restore(r.data); app.status = "Restored \(n) series." }
                catch { app.report(error) }
                pendingRestore = nil
            }
        } message: { Text("\(pendingRestore?.name ?? "") will replace everything in your library and your settings. Saving a backup first is a good idea.") }
    }

    var autoBackupHint: String {
        guard let l = library.latestAutoBackup else { return "One dated backup a day, kept in Folio\u{2019}s data folder." }
        return "Last: " + l.date.formatted(date: .abbreviated, time: .shortened)
    }

    func saveBackup() {
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        p.nameFieldStringValue = "Folio \(f.string(from: Date())).foliobackup"
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try library.backupData().write(to: u); app.status = "Backup saved." }
        catch { app.report(error) }
    }

    func chooseRestore() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        pendingRestore = (d, u.lastPathComponent)
    }

    func chooseImport() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        importing = true; importNote = "Reading \(u.lastPathComponent)…"
        Task {
            defer { importing = false }
            do {
                let report: @Sendable (Int, Int) -> Void = { done, total in Task { @MainActor in importNote = "Importing \(done) of \(total)…" } }
                let items = TachimangaBackup.looksLike(d, name: u.lastPathComponent)
                    ? try await ExtensionEngine.shared.importTachimangaBackup(d, progress: report)
                    : try await ExtensionEngine.shared.importTachiyomiBackup(d, name: u.lastPathComponent, progress: report)
                let r = library.importSeries(items)
                importNote = "Added \(r.added) series" + (r.skipped > 0 ? ", skipped \(r.skipped) already in your library." : ".")
                app.status = importNote
            } catch { importNote = nil; app.report(error) }
        }
    }
}

struct SettingsAbout: View {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetRow(label: "Version") { Text(Self.version).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.dim) }
            SetRow(label: "Source code", hint: "Folio is open source.") {
                TextAction(title: "GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/AyushHRMSingh/Folio")!) }
            }
            SetRow(label: "Extension engine", hint: "Extensions run through the open-source Suwayomi server (MPL-2.0), downloaded from its official releases on first use.") { EmptyView() }
            SetSection(title: "Content") {
                NoticePoints().padding(.vertical, 13)
            }
        }
    }
}
