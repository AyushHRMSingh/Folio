import AppKit
import FolioCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var name = ""
    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var testing = false
    @State private var usage: Library.StorageUsage?
    @State private var flareURL = ""
    @State private var confirmDownloads = false
    @State private var showCategories = false
    @State private var pendingRestore: (data: Data, name: String)?
    @State private var importNote: String?
    @State private var importing = false
    @State private var tab: Tab = .general
    @State private var addingServer = false
    @State private var confirmHistory = false

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", library = "Library", reader = "Reader", downloads = "Downloads", sources = "Sources", backup = "Backup"
        var id: String { rawValue }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(.system(size: 34, weight: .light)).tracking(-1).foregroundStyle(Theme.ink).padding(.top, 8)
                HStack(spacing: 22) {
                    ForEach(Tab.allCases) { t in
                        Button { tab = t } label: {
                            Text(t.rawValue).font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? Theme.ink : Theme.dim)
                                .overlay(alignment: .bottom) { if tab == t { Rectangle().fill(Theme.ink).frame(height: 1.5).offset(y: 5) } }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 14).padding(.bottom, 4)

                if tab == .general {
                SetSection(title: "Appearance") {
                    SetRow(label: "Theme") {
                        MonoChoice(options: AppearanceMode.allCases.map { ($0, $0.label) }, selection: $library.settings.appearance)
                    }
                }

                SetSection(title: "Privacy") {
                    SetRow(label: "Incognito", hint: "While on, Folio doesn't save reading progress or history.") { MonoSwitch(isOn: $library.settings.incognito) }
                    SetRow(label: "Reading history") { TextAction(title: "clear…") { confirmHistory = true } }
                }

                SetSection(title: "Network") {
                    SetRow(label: "Cloudflare solver",
                           hint: "Optional. A running FlareSolverr lets extensions read sources behind Cloudflare checks. Press return to save; restarts the engine.") {
                        MonoField(placeholder: "http://127.0.0.1:8191/v1", text: $flareURL).onSubmit { applyFlare() }
                    }
                }

                }
                if tab == .library {
                SetSection(title: "Library") {
                    SetRow(label: "Display options", hint: "Layout, cover size, columns and counters are in the library's View menu.") { EmptyView() }
                    SetRow(label: "Categories", hint: "\(library.settings.categories.count) so far") {
                        TextAction(title: "edit") { showCategories = true }
                    }
                    SetRow(label: "Check for new chapters", hint: updateHint) {
                        Menu {
                            ForEach(UpdateInterval.allCases) { i in
                                Button { library.settings.updateInterval = i } label: {
                                    if i == library.settings.updateInterval { Label(i.label, systemImage: "checkmark") } else { Text(i.label) }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) { Text(library.settings.updateInterval.label.lowercased()).font(.system(size: 12, design: .monospaced)); Text("▾").font(.system(size: 9)) }
                                .foregroundStyle(Theme.ink).padding(.horizontal, 9).padding(.vertical, 4)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    if library.settings.updateInterval != .off {
                        SetRow(label: "Skip completed series") { MonoSwitch(isOn: $library.settings.updateRules.skipCompleted) }
                        SetRow(label: "Skip series with unread chapters", hint: "Nothing new to tell you while you\u{2019}re behind.") { MonoSwitch(isOn: $library.settings.updateRules.skipWithUnread) }
                        SetRow(label: "Skip series you haven\u{2019}t started") { MonoSwitch(isOn: $library.settings.updateRules.skipNotStarted) }
                        if !library.settings.categories.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Skip categories").font(.system(size: 13)).foregroundStyle(Theme.ink)
                                FlowLayout(spacing: 6) {
                                    ForEach(library.settings.categories) { c in
                                        let on = library.settings.updateRules.excludedCategories.contains(c.id)
                                        Button {
                                            if on { library.settings.updateRules.excludedCategories.removeAll { $0 == c.id } }
                                            else { library.settings.updateRules.excludedCategories.append(c.id) }
                                        } label: {
                                            Text(c.name).font(.system(size: 12)).foregroundStyle(on ? Theme.onInk : Theme.dim)
                                                .padding(.horizontal, 10).padding(.vertical, 5)
                                                .background(on ? Theme.ink : Color.clear, in: Capsule())
                                                .overlay { if !on { Capsule().strokeBorder(Theme.line) } }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                }

                }
                if tab == .reader {
                SetSection(title: "Reader") {
                    SetRow(label: "Default reading mode") {
                        MonoChoice(options: ReadingMode.allCases.map { ($0, $0.label) }, selection: $library.settings.defaultMode)
                    }
                    SetRow(label: "Page width (webtoon)") {
                        HStack(spacing: 10) {
                            Slider(value: $library.settings.webtoonWidth, in: 0.3...1).controlSize(.small).frame(width: 150)
                            Text("\(Int(library.settings.webtoonWidth * 100))%").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
                        }
                    }
                    SetRow(label: "Continuous scrolling between chapters") { MonoSwitch(isOn: $library.settings.seamlessChapters) }
                    SetRow(label: "Background") {
                        MonoChoice(options: [(ReaderBackground.black, "black"), (.gray, "gray"), (.white, "white"), (.auto, "auto")], selection: $library.settings.readerBackground)
                    }
                    SetRow(label: "Show page number") { MonoSwitch(isOn: $library.settings.showPageNumber) }
                    SetRow(label: "Pages decoded ahead", hint: "Every page of a chapter is fetched as soon as you open it; this is how many are ready to draw.") {
                        MonoStep(value: $library.settings.preloadPages, range: 1...10)
                    }
                }

                }
                if tab == .downloads {
                SetSection(title: "Downloads") {
                    SetRow(label: "Chapters downloaded at a time") { MonoStep(value: $library.settings.parallelDownloads, range: 1...5) }
                    SetRow(label: "Delete downloads after reading", hint: "Bookmarked chapters are kept.") { MonoSwitch(isOn: $library.settings.deleteAfterRead) }
                }

                SetSection(title: "Storage") {
                    SetRow(label: "Downloaded chapters", hint: usage.map { Self.bytes($0.downloads) } ?? "…") {
                        TextAction(title: "delete all", disabled: (usage?.downloads ?? 0) == 0) { confirmDownloads = true }
                    }
                    SetRow(label: "Cache", hint: usage.map { Self.bytes($0.cache) } ?? "…") {
                        TextAction(title: "clear", disabled: (usage?.cache ?? 0) == 0) { library.clearCache(); Task { await refreshUsage() }; app.status = "Cache cleared." }
                    }
                    SetRow(label: "Data folder") {
                        Text(Paths.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                            .lineLimit(1).truncationMode(.head).textSelection(.enabled).frame(maxWidth: 360, alignment: .trailing)
                    }
                }

                }
                if tab == .backup {
                SetSection(title: "Backup") {
                    SetRow(label: "Back up now", hint: "Library, reading progress, categories, settings and picked covers. Downloads aren\u{2019}t included.") {
                        TextAction(title: "save to file…") { saveBackup() }
                    }
                    SetRow(label: "Restore", hint: "Replaces your library with a Folio backup.") {
                        TextAction(title: "choose file…") { chooseRestore() }
                    }
                    SetRow(label: "Import from Tachiyomi, Mihon or Tachimanga",
                           hint: importNote ?? "A .tmb, .tachibk or .proto.gz backup. Adds its library; needs the engine, and each source\u{2019}s extension must be installed to read.") {
                        HStack(spacing: 10) {
                            if importing { ProgressView().controlSize(.small) }
                            TextAction(title: "import…", disabled: importing) { chooseImport() }
                        }
                    }
                    SetRow(label: "Automatic backup", hint: autoBackupHint) { MonoSwitch(isOn: $library.settings.autoBackup) }
                    if library.settings.autoBackup {
                        SetRow(label: "Keep the last") { MonoStep(value: $library.settings.backupsKept, range: 1...20) }
                        SetRow(label: "Backups folder") { TextAction(title: "show in finder") { NSWorkspace.shared.open(Paths.backups) } }
                    }
                }

                }
                if tab == .sources {
                SetSection(title: "Servers · OPDS") {
                    ForEach(library.settings.servers) { sv in
                        SetRow(label: sv.name, hint: sv.url) {
                            TextAction(title: "remove") { library.settings.servers.removeAll { $0.id == sv.id } }
                        }
                    }
                    if library.settings.servers.isEmpty {
                        SetRow(label: "No servers", hint: "Works with Komga, Kavita and Calibre-Web.") { EmptyView() }
                    }
                    HStack { TextAction(title: "add server…") { addingServer = true }; Spacer() }.padding(.top, 14)
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)      // full width: no empty margin on the right
            .padding(.horizontal, Theme.pad).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .task { flareURL = library.settings.flareSolverrURL; await refreshUsage() }
        .sheet(isPresented: $showCategories) { CategoriesSheet(library: library) }
        .sheet(isPresented: $addingServer) { addServerSheet }
        .confirmationDialog("Clear reading history?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) { library.clearHistory(); app.status = "History cleared." }
        } message: { Text("Your Recent list will be emptied. Reading progress on chapters is kept.") }
        .confirmationDialog("Replace your library with this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Replace Library", role: .destructive) {
                guard let r = pendingRestore else { return }
                do { let n = try library.restore(r.data); app.status = "Restored \(n) series." }
                catch { app.report(error) }
                pendingRestore = nil
            }
        } message: { Text("\(pendingRestore?.name ?? "") will replace everything in your library and your settings. Saving a backup first is a good idea.") }
        .confirmationDialog("Delete every downloaded chapter?", isPresented: $confirmDownloads, titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) { library.clearAllDownloads(); Task { await refreshUsage() } }
        } message: { Text("You can download them again later. This can't be undone.") }
    }

    var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Add OPDS server")
            SetRow(label: "Name") { MonoField(placeholder: "My Komga", text: $name) }
            SetRow(label: "Catalog URL") { MonoField(placeholder: "https://komga.example.com/opds/v1.2/catalog", text: $url) }
            SetRow(label: "Username") { MonoField(placeholder: "", text: $user) }
            SetRow(label: "Password", hint: "Works with Komga, Kavita and Calibre-Web.") { MonoField(placeholder: "", text: $pass, secure: true) }
            HStack(spacing: 12) {
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Cancel") { addingServer = false }.buttonStyle(.mono)
                Button("Test & add") { Task { await addServer(); if !library.settings.servers.isEmpty && url.isEmpty { addingServer = false } } }
                    .buttonStyle(.monoPrimary).disabled(url.isEmpty || testing)
            }
            .padding(.top, 16)
        }
        .padding(Theme.pad).frame(width: 520).background(Theme.bg)
    }

    var updateHint: String {
        let i = library.settings.updateInterval
        let rules = "These rules apply to automatic checks; the library\u{2019}s update button checks everything."
        guard i != .off else { return "Use the update button in the library when you want to check." }
        let last = library.settings.lastAutoUpdate.map { "Last checked " + $0.formatted(date: .abbreviated, time: .shortened) + ". " } ?? ""
        return last + rules
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

    func applyFlare() {
        let u = flareURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u != library.settings.flareSolverrURL else { return }
        library.settings.flareSolverrURL = u
        ExtensionEngine.shared.flareSolverrURL = u
        app.status = u.isEmpty ? "Cloudflare solver off." : "Cloudflare solver saved."
        Task.detached { ExtensionEngine.shared.stop() }     // next use starts it with the new setting
    }

    func refreshUsage() async {
        let d = await Task.detached { Library.size(of: Paths.downloads) }.value
        let c = await Task.detached { Library.size(of: Paths.cache) + ExtensionEngine.cacheSize() }.value
        usage = .init(downloads: d, cache: c)
    }

    func addServer() async {
        testing = true
        defer { testing = false }
        let s = OPDSServer(name: name.isEmpty ? (URL(string: url)?.host ?? "Server") : name,
                           url: url.trimmingCharacters(in: .whitespaces), username: user, password: pass)
        do {
            let r = try await OPDSSource(s).popular(page: 1)
            library.settings.servers.append(s)
            app.status = "Connected to \(s.name) (\(r.series.count) items)."
            name = ""; url = ""; user = ""; pass = ""
        } catch { app.report(error) }
    }
}

