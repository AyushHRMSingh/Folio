import FolioCore
import SwiftUI

@MainActor
final class ExtensionsModel: ObservableObject {
    @Published var engineState: ExtensionEngine.State = ExtensionEngine.shared.state
    @Published var repos: [ExtensionRepo] = []
    @Published var all: [ExtensionInfo] = []
    @Published var busy: Set<String> = []
    @Published var loading = false
    @Published var loaded = false

    weak var app: AppModel?

    init() {
        ExtensionEngine.shared.onStateChange = { [weak self] s in Task { @MainActor in self?.engineState = s } }
    }

    func load(refresh: Bool) async {
        guard let app else { return }
        loading = true
        defer { loading = false }
        do {
            repos = try await ExtensionEngine.shared.repos()
            all = refresh || !loaded ? try await ExtensionEngine.shared.refreshExtensions() : try await ExtensionEngine.shared.extensions()
            loaded = true
            try await app.library.syncExtensionSources()
        } catch {
            if ExtensionEngine.shared.state != .needsJava { app.report(error) }     // the page shows its own Java panel
        }
    }

    func addRepo(_ url: String) async -> Bool {
        guard let app else { return false }
        do {
            let r = try await ExtensionEngine.shared.addRepo(url)
            app.status = "Added \(r.name)."
            await load(refresh: true)
            return true
        } catch { app.report(error); return false }
    }

    func removeRepo(_ r: ExtensionRepo) async {
        do { try await ExtensionEngine.shared.removeRepo(r.indexURL); await load(refresh: true) } catch { app?.report(error) }
    }

    func perform(_ a: ExtensionEngine.ExtensionAction, _ e: ExtensionInfo) async {
        guard let app else { return }
        busy.insert(e.pkgName)
        defer { busy.remove(e.pkgName) }
        do {
            try await ExtensionEngine.shared.perform(a, e.pkgName)
            all = try await ExtensionEngine.shared.extensions()
            try await app.library.syncExtensionSources()
            app.status = switch a {
            case .install: "Installed \(e.name). Its sources are in the sidebar."
            case .update: "Updated \(e.name)."
            case .uninstall: "Removed \(e.name)."
            }
        } catch { app.report(error) }
    }
}

struct ExtensionsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: ExtensionsModel
    @ObservedObject var library: Library
    @State private var tab: Tab = .installed
    @State private var tabChosen = false
    @State private var query = ""
    @State private var newRepo = ""
    @State private var showRepos = false

    enum Tab: String, CaseIterable { case installed = "Installed", updates = "Updates", available = "Available" }

    var filtered: [ExtensionInfo] {
        model.all
            .filter {
                switch tab {
                case .installed: $0.installed
                case .updates: $0.installed && $0.hasUpdate
                case .available: !$0.installed
                }
            }
            .filter { tab != .available || library.settings.languages.isEmpty || library.settings.languages.contains($0.lang) }
            .filter { library.settings.showNSFW || !$0.nsfw }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var languages: [String] { Array(Set(model.all.map(\.lang))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                BackLink(title: "Sources") { if !app.path.isEmpty { app.path.removeLast() } }
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text("Extensions").font(.system(size: 36, weight: .light)).tracking(-1).foregroundStyle(Theme.ink)
                    Spacer(minLength: 12)
                    if accepted && model.engineState != .needsJava {
                        MonoField(placeholder: "Search extensions", text: $query, width: 200)
                        headerTools
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pad).padding(.top, 8).padding(.bottom, 6)
            if !accepted {
                ExtensionsNoticePanel(onAccept: { library.settings.extensionsNoticeAccepted = Date() },
                                      onDecline: { if !app.path.isEmpty { app.path.removeLast() } })
            } else if model.engineState == .needsJava {
                JavaPanel { Task { await model.load(refresh: false) } }
            } else {
                EngineBar(model: model)
                catalogue
            }
        }
        .background(Theme.bg)
        .navigationTitle("Extensions")
        .toolbar(app.fullPage ? .hidden : .visible, for: .windowToolbar)
        .sheet(isPresented: $showRepos) { ReposSheet(model: model) }
        // Nothing starts (and nothing is downloaded) until the notice has been accepted.
        .task { model.app = app; if accepted, !model.loaded { await model.load(refresh: false) } }
        .onChange(of: model.loaded) { _, l in
            // Open on what you have; fall back to the catalogue when nothing is installed yet.
            if l, !tabChosen { tab = model.all.contains(where: \.installed) ? .installed : .available }
        }
        .onChange(of: accepted) { _, ok in if ok, !model.loaded { Task { await model.load(refresh: false) } } }
        .onChange(of: updateCount) { _, n in if n == 0 && tab == .updates { tab = .installed } }
    }

    var accepted: Bool { library.settings.extensionsNoticeAccepted != nil }

    @ViewBuilder var catalogue: some View {
            if model.repos.isEmpty && model.loaded {
                addRepoPrompt
            } else {
                HStack(spacing: 25) {
                    ForEach(Tab.allCases.filter { $0 != .updates || updateCount > 0 }, id: \.self) { t in
                        Button { tab = t; tabChosen = true } label: {
                            Text(t == .updates ? "Updates (\(updateCount))" : t.rawValue)
                                .font(.system(size: 14.5, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? Theme.ink : Theme.dim)
                                .overlay(alignment: .bottom) { if tab == t { Rectangle().fill(Theme.ink).frame(height: 1.5).offset(y: 5) } }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.pad).padding(.vertical, 18)
                ScrollView { LazyVStack(spacing: 0) { ForEach(filtered) { e in ExtensionRow(model: model, e: e) } }.padding(.horizontal, Theme.pad).padding(.bottom, 40) }
                    .overlay {
                        if model.loading && model.all.isEmpty { ProgressView("Loading extensions…") }
                        else if filtered.isEmpty && model.loaded {
                            ContentUnavailableView(tab == .installed ? "No extensions installed" : "Nothing here", systemImage: "puzzlepiece.extension")
                        }
                    }
            }
    }

    /// Page tools live in the page header, never the title bar.
    var headerTools: some View {
        HStack(spacing: 20) {
            Menu {
                Section("Languages") {
                    Button(library.settings.languages.isEmpty ? "✓ All languages" : "All languages") { library.settings.languages = [] }
                    ForEach(languages, id: \.self) { l in
                        Toggle(Self.langName(l), isOn: Binding(
                            get: { library.settings.languages.contains(l) },
                            set: { on in
                                var s = Set(library.settings.languages); if on { s.insert(l) } else { s.remove(l) }
                                library.settings.languages = Array(s).sorted()
                            }))
                    }
                }
                Toggle("Show 18+ extensions", isOn: $library.settings.showNSFW)
            } label: { ToolMenuLabel(title: "Filter") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button { showRepos = true } label: { ToolMenuLabel(title: "Repos", chevron: false) }
                .buttonStyle(.plain)
            Button { Task { await model.load(refresh: true) } } label: { ToolMenuLabel(title: "", chevron: false, icon: "arrow.clockwise") }
                .buttonStyle(.plain).help("Re-download every repo's extension list")
        }
    }

    var updateCount: Int { model.all.filter { $0.installed && $0.hasUpdate }.count }

    var addRepoPrompt: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("Add an extension repo")
            Text("Paste a Tachiyomi or Mihon extension repo link ending in index.pb or index.min.json.")
                .font(.system(size: 14.5)).foregroundStyle(Theme.dim).lineSpacing(3).frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 12) {
                MonoField(placeholder: "https://…/index.pb", text: $newRepo, width: 400)
                    .padding(.horizontal, 10).padding(.vertical, 9).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .onSubmit { Task { if await model.addRepo(newRepo) { newRepo = "" } } }
                Button("Add") { Task { if await model.addRepo(newRepo) { newRepo = "" } } }
                    .buttonStyle(.monoPrimary).disabled(newRepo.isEmpty)
            }
        }
        .padding(Theme.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static func langName(_ code: String) -> String {
        if code == "all" { return "Multi-language" }
        return Locale.current.localizedString(forIdentifier: code).map { "\($0) (\(code))" } ?? code
    }
}

struct EngineBar: View {
    @ObservedObject var model: ExtensionsModel
    var body: some View {
        HStack(spacing: 10) {
            switch model.engineState {
            case .running:
                Image(systemName: "circle.fill").foregroundStyle(Theme.ink).font(.system(size: 6))
                Text("Extension engine running")
            case .starting:
                ProgressView().controlSize(.small); Text("Starting extension engine…")
            case .downloading(let f):
                ProgressView(value: f).frame(width: 120); Text("Downloading extension engine (one time, \(Int(f * 100))%)…")
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.ink)
                Text(m).lineLimit(2).textSelection(.enabled)
                Button("Retry") { Task { await model.load(refresh: false) } }.buttonStyle(.mono)
            case .needsJava:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.ink)
                Text("Java 21 isn't installed")
            case .stopped:
                Image(systemName: "circle").font(.system(size: 6)); Text("Extension engine stopped")
                Button("Start") { Task { await model.load(refresh: false) } }.buttonStyle(.mono)
            }
            Spacer()
        }
        .font(.system(size: 13)).foregroundStyle(Theme.dim)
        .padding(.horizontal, Theme.pad).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct ExtensionRow: View {
    @ObservedObject var model: ExtensionsModel
    let e: ExtensionInfo
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 15) {
            Group {
                if let icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "puzzlepiece.extension").font(.system(size: 20)).foregroundStyle(Theme.faint) }
            }
            .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(e.name).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Theme.ink)
                    if e.nsfw { Text("18+").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim) }
                    if e.obsolete { Text("obsolete").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim) }
                }
                Text("\(ExtensionsView.langName(e.lang)) · v\(e.version)").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.faint)
            }
            Spacer()
            if model.busy.contains(e.pkgName) {
                ProgressView().controlSize(.small)
            } else if e.installed {
                if e.hasUpdate { Button("Update") { Task { await model.perform(.update, e) } }.buttonStyle(.monoPrimary) }
                Button("Uninstall") { Task { await model.perform(.uninstall, e) } }.buttonStyle(.mono)
            } else {
                Button("Install") { Task { await model.perform(.install, e) } }.buttonStyle(.mono)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .task(id: e.iconPath) {
            guard let p = e.iconPath else { return }
            icon = await Images.shared.image("exticon|" + p) { try await ExtensionEngine.shared.fetch(p) }
        }
    }
}

struct ReposSheet: View {
    @ObservedObject var model: ExtensionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("Extension repos")
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.repos) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.ink)
                                Text(r.indexURL).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.faint).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") { Task { await model.removeRepo(r) } }.buttonStyle(.mono)
                        }
                        .padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    }
                }
            }
            .frame(minHeight: 140)
            HStack(spacing: 12) {
                MonoField(placeholder: "https://…/index.pb", text: $url, width: 360)
                    .padding(.horizontal, 10).padding(.vertical, 9).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                Button("Add") { Task { if await model.addRepo(url) { url = "" } } }.buttonStyle(.monoPrimary).disabled(url.isEmpty)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.mono).keyboardShortcut(.defaultAction) }
        }
        .padding(Theme.pad).background(Theme.bg)
        .frame(width: 560, height: 380)
    }
}

// MARK: - Notices

/// The wording shown before extensions can be used, and again in Settings and About.
enum FolioNotice {
    static let title = "Before you add extensions"
    static let points = [
        "Folio is a reader. It comes with no content, no extension repos and no sources.",
        "Extensions and repos are made by third parties. You choose what to add, and you alone are responsible for the content you import, read or download with Folio, and for following the law where you live.",
        "Folio does not condone reading copyrighted work without paying for it. When a series is officially available, read it there and support the people who make it.",
    ]
}

struct NoticePoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(FolioNotice.points, id: \.self) { p in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("·").foregroundStyle(Theme.faint)
                    Text(p).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 14.5)).lineSpacing(3)
    }
}

/// Shown once, before anything extension-related starts or downloads.
struct ExtensionsNoticePanel: View {
    let onAccept: () -> Void
    let onDecline: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(FolioNotice.title)
                NoticePoints()
                HStack(spacing: 12) {
                    Button("I understand and accept", action: onAccept).buttonStyle(.monoPrimary)
                    Button("Not now", action: onDecline).buttonStyle(.mono)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.pad)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// No Java on this Mac: say what's needed and how to get it, in place of an error line.
struct JavaPanel: View {
    let checkAgain: () -> Void
    static let download = URL(string: "https://adoptium.net/temurin/releases/?os=mac&package=jdk&version=21")!
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow("Extensions need Java")
                Text("Folio runs extensions with the open-source Suwayomi engine, which needs Java 21 or newer. Java isn't installed on this Mac.")
                    .font(.system(size: 14.5)).foregroundStyle(Theme.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Download Java 21 (Temurin, from Adoptium) and pick the macOS .pkg.")
                    step(2, "Open the downloaded file and follow the installer.")
                    step(3, "Come back here and check again.")
                }
                HStack(spacing: 12) {
                    Button("Download Java 21…") { NSWorkspace.shared.open(Self.download) }.buttonStyle(.monoPrimary)
                    Button("Check again", action: checkAgain).buttonStyle(.mono)
                }
                Text("Using Homebrew? brew install openjdk@21 works too.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint).textSelection(.enabled)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(Theme.pad)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink).frame(width: 14)
            Text(t).font(.system(size: 14.5)).foregroundStyle(Theme.dim)
        }
    }
}
