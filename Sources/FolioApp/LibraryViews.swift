import FolioCore
import SwiftUI

// MARK: - Library

struct LibraryView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var filter = ""
    @State private var category: String?                 // nil = all
    @State private var assigningID: String?
    @State private var showCategories = false
    @FocusState private var searchFocused: Bool
    @ObservedObject private var sourceSearch: GlobalSearchModel

    init(app: AppModel, library: Library) {
        self.app = app; self.library = library; self.sourceSearch = app.search
    }

    var settings: FolioSettings { library.settings }
    var query: String { filter.trimmingCharacters(in: .whitespaces) }
    var items: [LibraryEntry] { library.browse(category: category, query: filter) }

    var continueItems: [LibraryEntry] {
        Array(library.recents.filter { $0.isSaved }.filter { e in e.resumeChapter.map { $0.started || !$0.read } ?? false }.prefix(12))
    }

    var gap: CGFloat { settings.gridGap.points }

    /// Exactly N columns, or as many as fit at the chosen cover width.
    var columns: [GridItem] {
        if let n = settings.gridColumns, n > 0 {
            return Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .top), count: n)
        }
        let base = settings.libraryDisplay == .compact ? settings.gridSize * 0.78 : settings.gridSize
        return [GridItem(.adaptive(minimum: base, maximum: base * 1.3), spacing: gap, alignment: .top)]
    }

    /// One box for everything: filters your library as you type; return also searches every source.
    var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("search your library — return searches every source", text: $filter)
                    .textFieldStyle(.plain).font(.system(size: 18, weight: .light)).foregroundStyle(Theme.ink)
                    .focused($searchFocused)
                    .onSubmit { if !query.isEmpty { sourceSearch.run(query, library: library) } }
                if sourceSearch.searching { ProgressView().controlSize(.small) }
                if !filter.isEmpty {
                    if sourceSearch.searched != query {
                        Text("↵ sources").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                    }
                    Button { filter = "" } label: { Text("✕").font(.system(size: 12, design: .monospaced)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, Theme.pad).padding(.top, 10).padding(.bottom, 10)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Theme.pad)
        }
    }

    /// One header: title and count on the left, search and tools on the right.
    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            SectionTitle(title, count: items.count).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            searchField
            LibraryTools(app: app, library: library)
        }
        .padding(.horizontal, Theme.pad).padding(.top, 14).padding(.bottom, 6)
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
            TextField("Search library", text: $filter)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onSubmit { if !query.isEmpty { sourceSearch.run(query, library: library) } }
            if sourceSearch.searching { ProgressView().controlSize(.small) }
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 110, maxWidth: 220)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !library.savedEntries.isEmpty { header }
            if !library.savedEntries.isEmpty && (!settings.categories.isEmpty) {
                CategoryBar(library: library, selection: $category, onManage: { showCategories = true })
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            content
        }
        .navigationTitle("Library")
        .sheet(isPresented: $showCategories) { CategoriesSheet(library: library) }
        .sheet(isPresented: Binding(get: { assigningID != nil }, set: { if !$0 { assigningID = nil } })) {
            if let id = assigningID { AssignCategoriesSheet(library: library, seriesID: id) }
        }
        .onChange(of: app.searchFocus) { _, _ in searchFocused = true }
        .onChange(of: filter) { _, f in if f.trimmingCharacters(in: .whitespaces).isEmpty { sourceSearch.run("", library: library) } }
        .onChange(of: settings.categories) { _, c in if let cur = category, !c.contains(where: { $0.id == cur }) { category = nil } }
    }

    @ViewBuilder var content: some View {
        let items = self.items
        let q = query
        if library.savedEntries.isEmpty && q.isEmpty {
            VStack(spacing: 22) {
                Text("Your library is empty.\nBetter start reading.")
                    .font(.system(size: 28, weight: .light)).tracking(-0.6).multilineTextAlignment(.center)
                    .foregroundStyle(Theme.faint)
                HStack(spacing: 10) {
                    Button("Browse sources") { app.sidebar = .sources; app.path = NavigationPath() }.buttonStyle(.monoPrimary)
                    Button("Import files…") { app.importLocal() }.buttonStyle(.mono)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty && q.isEmpty {
            VStack(spacing: 14) {
                Text(settings.filters.active ? "No matches." : "Nothing in this category.")
                    .font(.system(size: 28, weight: .light)).tracking(-0.6).foregroundStyle(Theme.faint)
                HStack(spacing: 10) {
                    if settings.filters.active { TextAction(title: "clear filters") { library.settings.filters = LibraryFilters() } }
                    if category != nil { TextAction(title: "show all") { category = nil } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 16) {
                        if !q.isEmpty {
                            Button { sourceSearch.run(q, library: library) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "globe").font(.system(size: 12))
                                    Text("Search all sources for “\(q)”").font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.system(size: 11))
                                }
                                .foregroundStyle(Theme.ink).padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if items.isEmpty {
                            Text("Nothing in your library matches “\(q)”.").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
                        } else if settings.libraryDisplay == .list {
                            LazyVStack(spacing: 0) { ForEach(items) { e in row(e) } }
                        } else {
                            LazyVGrid(columns: columns, spacing: gap + 4) { ForEach(items) { e in card(e) } }
                        }
                    }
                    if !q.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Eyebrow("In sources")
                            if sourceSearch.searched == q {
                                SourceResults(app: app, model: sourceSearch, library: library)
                            } else {
                                Text("Use “Search all sources” above to look beyond your library.")
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
                            }
                        }
                    }
                }
                .padding(Theme.pad)
            }
        }
    }

    var title: String {
        if !filter.isEmpty { return "Results" }
        if let c = category, let cat = settings.categories.first(where: { $0.id == c }) { return cat.name }
        return "All Series"
    }

    func progress(_ e: LibraryEntry) -> Double? {
        e.chapters.isEmpty ? nil : Double(e.chapters.count - e.unread) / Double(e.chapters.count)
    }

    func card(_ e: LibraryEntry) -> some View {
        NavigationLink(value: e.series) {
            SeriesCard(series: e.series, source: library.source(e.series.sourceID),
                       badge: settings.showBadges ? e.unread : 0, downloaded: settings.showDownloadBadge ? e.downloadedCount : 0,
                       progress: progress(e), compact: settings.libraryDisplay == .compact, titles: settings.cardTitles, isNew: settings.showNewTag && e.hasNew)
        }
        .buttonStyle(.plain)
        .contextMenu { EntryMenu(app: app, library: library, entry: e, assign: { assigningID = e.id }) }
    }

    func row(_ e: LibraryEntry) -> some View {
        NavigationLink(value: e.series) { LibraryListRow(library: library, entry: e, badges: settings.showBadges) }
            .buttonStyle(.plain)
            .contextMenu { EntryMenu(app: app, library: library, entry: e, assign: { assigningID = e.id }) }
    }
}

/// The library's controls, as words on the page: view, filter, sort, and a few actions.
struct LibraryTools: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    var st: FolioSettings { library.settings }

    var body: some View {
        HStack(spacing: 4) {
            ToolPopover(title: "View") { viewPanel }
            ToolPopover(title: st.filters.active ? "Filter ●" : "Filter", active: st.filters.active) { filterPanel }
            ToolPopover(title: "Sort") { sortPanel }
            Button { app.updateLibrary() } label: {
                Group {
                    if app.updating { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 26, height: 24).foregroundStyle(Theme.dim).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(app.updating).help("Update library")
            Menu {
                Button("Random series") { if let e = library.randomEntry() { app.path.append(e.series) } }
                Button("Import files…") { app.importLocal() }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 24).foregroundStyle(Theme.dim) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    func toolButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim) }.buttonStyle(.plain)
    }

    // MARK: panels

    var viewPanel: some View {
        VStack(spacing: 0) {
            SetRow(label: "Layout") {
                MonoChoice(options: LibraryDisplay.allCases.map { ($0, $0.label) }, selection: $library.settings.libraryDisplay)
            }
            if st.libraryDisplay != .list {
                SetRow(label: "Cover size") {
                    HStack(spacing: 10) {
                        Slider(value: $library.settings.gridSize, in: 90...320).controlSize(.small).frame(width: 130)
                        Text("\(Int(st.gridSize))").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim).frame(width: 28, alignment: .trailing)
                    }
                }
                SetRow(label: "Columns", hint: st.gridColumns == nil ? "as many as fit" : "exactly \(st.gridColumns!)") {
                    MonoChoice(options: [(0, "auto")] + [3, 4, 5, 6, 8, 10].map { ($0, "\($0)") },
                               selection: Binding(get: { st.gridColumns ?? 0 }, set: { library.settings.gridColumns = $0 == 0 ? nil : $0 }))
                }
                SetRow(label: "Spacing") { MonoChoice(options: GridGap.allCases.map { ($0, $0.label) }, selection: $library.settings.gridGap) }
                SetRow(label: "Titles") { MonoChoice(options: CardTitles.allCases.map { ($0, $0.label) }, selection: $library.settings.cardTitles) }
            }
            SetRow(label: "Unread counter") { MonoSwitch(isOn: $library.settings.showBadges) }
            SetRow(label: "Downloaded counter") { MonoSwitch(isOn: $library.settings.showDownloadBadge) }
            SetRow(label: "New tag", hint: "unread chapters uploaded in the last 3 days") { MonoSwitch(isOn: $library.settings.showNewTag) }
        }
    }

    var filterPanel: some View {
        VStack(spacing: 0) {
            SetRow(label: "Unread") { MonoSwitch(isOn: $library.settings.filters.unread) }
            SetRow(label: "Downloaded") { MonoSwitch(isOn: $library.settings.filters.downloaded) }
            SetRow(label: "Started") { MonoSwitch(isOn: $library.settings.filters.started) }
            SetRow(label: "Bookmarked") { MonoSwitch(isOn: $library.settings.filters.bookmarked) }
            SetRow(label: "Completed") { MonoSwitch(isOn: $library.settings.filters.completed) }
            HStack { Spacer(); TextAction(title: "clear all", disabled: !st.filters.active) { library.settings.filters = LibraryFilters() } }.padding(.top, 12)
        }
    }

    var sortPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LibrarySort.allCases) { o in
                Button {
                    if st.librarySort == o { library.settings.sortAscending.toggle() }       // pick it again to flip it
                    else { library.settings.librarySort = o; library.settings.sortAscending = o.naturalAscending }
                } label: {
                    HStack {
                        Text(o.label).font(.system(size: 13, weight: st.librarySort == o ? .semibold : .regular))
                            .foregroundStyle(st.librarySort == o ? Theme.ink : Theme.dim)
                        Spacer()
                        if st.librarySort == o {
                            Text(st.sortAscending ? o.ascendingLabel : o.descendingLabel)
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
                .buttonStyle(.plain)
            }
            SetRow(label: "Order", hint: "or pick the same sort again") {
                MonoChoice(options: [(true, st.librarySort.ascendingLabel), (false, st.librarySort.descendingLabel)],
                           selection: $library.settings.sortAscending)
            }
        }
    }
}

/// A word that opens a small panel.
struct ToolPopover<Content: View>: View {
    let title: String
    var active = false
    @ViewBuilder let content: () -> Content
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .regular)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(active || open || hover ? Theme.ink : Theme.dim)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(hover || open ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            content().padding(.horizontal, 18).padding(.vertical, 12).frame(width: 360)
                .background(Theme.bg)
        }
    }
}

/// Right-click menu for a library series, shared by grid and list.
struct EntryMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    let entry: LibraryEntry
    let assign: () -> Void

    var body: some View {
        Button("Continue Reading") { app.resume(entry) }
        Button("Categories…", action: assign)
        Divider()
        Button("Mark All as Read") { library.markAll(entry.id, read: true) }.disabled(entry.unread == 0)
        Button("Mark All as Unread") { library.markAll(entry.id, read: false) }
        if entry.series.sourceID != "local" {
            Menu("Download") { DownloadMenuItems(library: library, entry: entry) }
        }
        Button("Check for New Chapters") {
            Task { do { let n = try await library.refresh(entry.id); app.status = n == 0 ? "No new chapters." : "\(n) new." } catch { app.report(error) } }
        }
        if entry.series.sourceID != "local" { Button("Migrate to Another Source…") { app.migrating = entry } }
        Divider()
        Button("Remove from Library", role: .destructive) { library.remove(entry.id) }
    }
}

/// Next 1 / 5 / 10 / all unread / everything — the same choices Tachimanga offers.
struct DownloadMenuItems: View {
    @ObservedObject var library: Library
    let entry: LibraryEntry

    var body: some View {
        Button("Next Chapter") { library.enqueueDownloads(entry.id, chapters: library.nextToDownload(entry.id, count: 1)) }
        Button("Next 5 Chapters") { library.enqueueDownloads(entry.id, chapters: library.nextToDownload(entry.id, count: 5)) }
        Button("Next 10 Chapters") { library.enqueueDownloads(entry.id, chapters: library.nextToDownload(entry.id, count: 10)) }
        Divider()
        Button("All Unread") { library.enqueueDownloads(entry.id, chapters: library.nextToDownload(entry.id, count: nil)) }
        Button("All Chapters") { library.enqueueDownloads(entry.id, chapters: entry.ordered.map(\.chapter.url)) }
    }
}

struct LibraryListRow: View {
    @ObservedObject var library: Library
    let entry: LibraryEntry
    let badges: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            CoverView(series: entry.series, source: library.source(entry.series.sourceID), corner: 4).frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.series.title).font(.rowTitle).foregroundStyle(Theme.ink).lineLimit(1)
                Text([entry.series.author, "\(entry.chapters.count) chapters"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.meta).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            if badges && entry.downloadedCount > 0 {
                Label("\(entry.downloadedCount)", systemImage: "arrow.down.circle").font(.meta.monospacedDigit()).foregroundStyle(Theme.dim)
            }
            if badges && entry.unread > 0 { Chip(text: "\(entry.unread)", filled: true) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Categories

struct CategoryBar: View {
    @ObservedObject var library: Library
    @Binding var selection: String?
    let onManage: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All", library.count(in: nil), selection == nil) { selection = nil }
                ForEach(library.settings.categories) { c in
                    pill(c.name, library.count(in: c.id), selection == c.id) { selection = c.id }
                }
                Button(action: onManage) { Text("Edit").font(.system(size: 12.5)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).padding(.leading, 6).help("Add, rename or delete categories")
            }
            .padding(.horizontal, Theme.pad).padding(.vertical, 10)
        }
    }

    func pill(_ title: String, _ count: Int, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).fontWeight(on ? .semibold : .regular)
                Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(on ? Theme.onInk.opacity(0.6) : Theme.faint)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 13).padding(.vertical, 5)
            .background(on ? Theme.ink : Color.clear, in: Capsule())
            .overlay { if !on { Capsule().strokeBorder(Theme.line) } }
            .foregroundStyle(on ? Theme.onInk : Theme.dim)
        }
        .buttonStyle(.plain)
    }
}

/// Create, rename, reorder and delete categories.
struct CategoriesSheet: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Categories").font(.title2.bold())
            Text("Group your library. A series can be in several categories.").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(library.settings.categories) { c in
                    HStack(spacing: 10) {
                        TextField("Name", text: Binding(get: { c.name }, set: { library.renameCategory(c.id, to: $0) }))
                            .textFieldStyle(.plain)
                        Text("\(library.count(in: c.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { library.moveCategory(c.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { library.moveCategory(c.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Button(role: .destructive) { library.deleteCategory(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 160)
            .overlay { if library.settings.categories.isEmpty { Text("No categories yet").foregroundStyle(.secondary) } }
            HStack {
                TextField("New category", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 440, height: 440)
    }

    func add() { if library.addCategory(newName) != nil { newName = "" } }
}

/// Choose which categories a series belongs to.
struct AssignCategoriesSheet: View {
    @ObservedObject var library: Library
    let seriesID: String
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var current: Set<String> { Set(library.entry(seriesID)?.categoryIDs ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Categories for “\(library.entry(seriesID)?.series.title ?? "")”").font(.title3.bold()).lineLimit(2)
            List(library.settings.categories) { c in
                Toggle(c.name, isOn: Binding(
                    get: { current.contains(c.id) },
                    set: { on in
                        var s = current; if on { s.insert(c.id) } else { s.remove(c.id) }
                        library.setCategories(seriesID, library.settings.categories.map(\.id).filter(s.contains))
                    }))
            }
            .frame(minHeight: 140)
            .overlay { if library.settings.categories.isEmpty { Text("Create your first category below").foregroundStyle(.secondary) } }
            HStack {
                TextField("New category", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 380, height: 380)
    }

    func add() {
        guard let c = library.addCategory(newName) else { return }
        library.setCategories(seriesID, Array(current) + [c.id])
        newName = ""
    }
}

// MARK: - Global search

@MainActor
final class GlobalSearchModel: ObservableObject {
    enum State: Equatable { case loading, done, failed(String) }
    struct Group: Identifiable {
        let id: String
        let name: String
        var state: State
        var series: [Series]
    }

    @Published var query = ""
    @Published var groups: [Group] = []
    @Published var searched = ""
    private var task: Task<Void, Never>?

    var searching: Bool { groups.contains { $0.state == .loading } }

    func run(_ q: String, library: Library) {
        let term = q.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !term.isEmpty else { groups = []; searched = ""; return }
        searched = term
        let sources: [Source] = [library.local] + library.settings.servers.map { library.opdsSource($0) } + library.visibleExtensionSources
        groups = sources.map { Group(id: $0.id, name: $0.name, state: .loading, series: []) }
        task = Task { [weak self] in
            await withTaskGroup(of: (String, Result<[Series], Error>).self) { g in
                var iterator = sources.makeIterator()
                var active = 0
                func next() -> Bool {
                    guard let s = iterator.next() else { return false }
                    g.addTask { do { return (s.id, .success(try await s.search(term, page: 1).series)) } catch { return (s.id, .failure(error)) } }
                    return true
                }
                while active < 4, next() { active += 1 }
                for await (id, r) in g {
                    guard !Task.isCancelled, let self, self.searched == term else { return }
                    if let i = self.groups.firstIndex(where: { $0.id == id }) {
                        switch r {
                        case .success(let list): self.groups[i].series = list; self.groups[i].state = .done
                        case .failure(let e): self.groups[i].state = .failed((e as? LocalizedError)?.errorDescription ?? "\(e)")
                        }
                    }
                    if next() { continue }
                }
            }
        }
    }
}

/// Results from every source, grouped by source, as they arrive.
struct SourceResults: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: GlobalSearchModel
    @ObservedObject var library: Library

    var withResults: [GlobalSearchModel.Group] { model.groups.filter { !$0.series.isEmpty } }
    var empty: [GlobalSearchModel.Group] { model.groups.filter { $0.state == .done && $0.series.isEmpty } }
    var pending: [GlobalSearchModel.Group] { model.groups.filter { $0.state == .loading } }
    var failed: [GlobalSearchModel.Group] { model.groups.filter { if case .failed = $0.state { true } else { false } } }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(withResults) { g in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(g.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("\(g.series.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(g.series) { s in
                                NavigationLink(value: s) {
                                    SeriesCard(series: s, source: library.source(s.sourceID), inLibrary: library.contains(s), compact: true,
                                               onToggleSave: { Task { await app.toggleSaved(s) } })
                                        .frame(width: 140)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
            }
            if !pending.isEmpty {
                Text("searching \(pending.map(\.name).joined(separator: ", "))…").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            ForEach(failed) { g in
                if case .failed(let m) = g.state { Text("\(g.name): \(m)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim) }
            }
            if !empty.isEmpty && !model.searching {
                Text("no results from \(empty.map(\.name).joined(separator: ", "))").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.faint)
            }
            if withResults.isEmpty && pending.isEmpty && !model.groups.isEmpty {
                Text("nothing found for “\(model.searched)”").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
            }
        }
    }
}
