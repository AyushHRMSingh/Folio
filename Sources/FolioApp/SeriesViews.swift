import AppKit
import FolioCore
import SwiftUI
import UniformTypeIdentifiers

struct SeriesView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    let series: Series
    @State private var preview: [Chapter] = []   // when not in library
    @State private var loading = false
    @State private var newestFirst = true
    @State private var expanded = false
    @State private var onlyUnread = false
    @State private var onlyDownloaded = false
    @State private var onlyBookmarked = false
    @State private var assigning = false
    @State private var selected = Set<String>()       // chapter urls (⌘/⇧-click)
    @State private var lastClicked: String?

    var entry: LibraryEntry? { library.entry(series.id) }
    var shown: Series { entry?.series ?? series }
    var source: Source? { library.source(series.sourceID) }

    var rows: [ChapterState] {
        var base = entry?.ordered ?? preview.readingOrder().map { ChapterState(chapter: $0) }
        if onlyUnread { base = base.filter { !$0.read } }
        if onlyDownloaded { base = base.filter(\.downloaded) }
        if onlyBookmarked { base = base.filter(\.bookmarked) }
        return newestFirst ? base.reversed() : base
    }

    var saved: Bool { library.contains(series) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackLink(title: "Back") { if !app.path.isEmpty { app.path.removeLast() } }.padding(.bottom, 14)
                header
                chapterBar.padding(.top, 28)
                if !selected.isEmpty { selectionBar.padding(.top, 10) }
                Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 10)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { c in
                        ChapterRow(app: app, library: library, series: shown, state: c, inLibrary: entry != nil,
                                   selected: selected.contains(c.chapter.url)) { cmd, shift in click(c, cmd: cmd, shift: shift) }
                    }
                }
                .overlay {
                    if loading && rows.isEmpty { ProgressView().padding(.top, 40) }
                }
                if rows.isEmpty && !loading && (onlyUnread || onlyDownloaded || onlyBookmarked) {
                    Text("No chapters match").font(.meta).foregroundStyle(Theme.dim).padding(.top, 30).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 940, alignment: .leading)            // lines stay readable on wide windows
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .sheet(isPresented: $assigning) { AssignCategoriesSheet(library: library, seriesID: series.id) }
        .task {
            await loadPreview()
            // Library entries saved before web addresses were remembered: fetch them once.
            if let e = entry, series.sourceID != "local", e.series.webURL == nil { _ = try? await library.refresh(e.id) }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
    }

    var header: some View {
        HStack(alignment: .top, spacing: 22) {
            CoverView(series: shown, source: source, corner: 3).frame(width: 112)
            VStack(alignment: .leading, spacing: 10) {
                Text(shown.title).font(.system(size: 30, weight: .light)).tracking(-0.9)
                    .foregroundStyle(Theme.ink).lineLimit(3).textSelection(.enabled)
                Text([shown.author, source?.name, shown.status == .unknown ? nil : shown.status.rawValue]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim)
                actions.padding(.vertical, 2)
                about
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 168, alignment: .top)
    }

    func click(_ c: ChapterState, cmd: Bool, shift: Bool) {
        let url = c.chapter.url
        if shift, let last = lastClicked, let a = rows.firstIndex(where: { $0.chapter.url == last }), let b = rows.firstIndex(where: { $0.id == c.id }) {
            for r in rows[min(a, b)...max(a, b)] { selected.insert(r.chapter.url) }
        } else if cmd {
            if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
        } else if !selected.isEmpty {
            selected = []
        } else {
            app.read(shown, c.chapter); return
        }
        lastClicked = url
    }

    var selectionBar: some View {
        HStack(spacing: 16) {
            Text("\(selected.count) selected").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            Button("Mark read") { library.setRead(series.id, chapters: Array(selected), true); selected = [] }
            Button("Mark unread") { library.setRead(series.id, chapters: Array(selected), false); selected = [] }
            Spacer()
            Button("Clear") { selected = [] }
        }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.dim)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = shown.summary, !d.isEmpty {
                Text(d).font(.system(size: 13)).foregroundStyle(Theme.dim).lineSpacing(4)
                    .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                Button(expanded ? "less" : "more") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink)
            }
            if !shown.genres.isEmpty {
                Text(shown.genres.joined(separator: "  /  ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
            }
        }
    }

    var chapterBar: some View {
        HStack(spacing: 14) {
            Text("\(rows.count) chapters").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            if let e = entry, e.unread > 0 {
                Text("\(e.unread) unread").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            Spacer()
            if entry != nil {
                Menu {
                    Toggle("Unread", isOn: $onlyUnread)
                    Toggle("Downloaded", isOn: $onlyDownloaded)
                    Toggle("Bookmarked", isOn: $onlyBookmarked)
                } label: {
                    Text({ let n = [onlyUnread, onlyDownloaded, onlyBookmarked].filter { $0 }.count; return n > 0 ? "filter · \(n)" : "filter" }())
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(onlyUnread || onlyDownloaded || onlyBookmarked ? Theme.ink : Theme.dim)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let e = entry {
                Button { Task { do { let n = try await library.refresh(e.id); app.status = n == 0 ? "No new chapters." : "\(n) new." } catch { app.report(error) } } }
                    label: { Text("refresh").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain).help("Check for new chapters")
            }
            Button { newestFirst.toggle() } label: {
                Text(newestFirst ? "newest ↓" : "oldest ↑").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
            }.buttonStyle(.plain)
        }
    }

    /// Save · Read · extras, in one row.
    @ViewBuilder var actions: some View {
        HStack(spacing: 8) {
            Button { Task { await app.toggleSaved(shown) } } label: {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16)).frame(width: 22, height: 22)
                    .foregroundStyle(saved ? Theme.ink : Theme.dim)
            }
            .buttonStyle(.monoLarge)
            .help(saved ? "In your library — click to remove" : "Add to your library")
            if let e = entry, !e.chapters.isEmpty {
                Button { app.resume(e) } label: {
                    HStack(spacing: 7) {
                        let started = e.chapters.contains { $0.read || $0.started }
                        if let c = e.resumeChapter {
                            Text("\(started ? "Continue" : "Read") · \(c.chapter.name)\(c.started ? " · p\(c.lastPage + 1)" : "")").lineLimit(1)
                        } else { Text(started ? "Continue" : "Read") }
                        Text("→")
                    }
                }
                .buttonStyle(.monoLargePrimary)
            } else if entry == nil, let first = preview.readingOrder().first {
                Button { app.read(series, first) } label: { Text("Read  →") }.buttonStyle(.monoLargePrimary)
            }
            if let e = entry {
                Menu { DownloadMenuItems(library: library, entry: e) } label: { Text("Download") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.mono).fixedSize()
                    .disabled(!saved || series.sourceID == "local")
                    .help(series.sourceID == "local" ? "Local files are already on this Mac" : (saved ? "Download chapters" : "Save to your library to download"))
                Menu {
                    if saved { Button("Categories…") { assigning = true } }
                    Picker("Reading mode", selection: Binding(get: { library.mode(for: e.id) }, set: { library.setMode(e.id, $0) })) {
                        ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Button("Mark all as read") { library.markAll(e.id, read: true) }.disabled(e.unread == 0)
                    Button("Mark all as unread") { library.markAll(e.id, read: false) }
                    if series.sourceID != "local" && saved { Button("Migrate to Another Source…") { app.migrating = e } }
                    if series.sourceID != "local" {
                        Divider()
                        Button("View in WebView") { app.openWeb(shown.webURL, title: shown.title) }
                    }
                } label: { Text("···") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.mono).fixedSize()
            }
        }
    }

    func loadPreview() async {
        guard entry == nil, preview.isEmpty, let source else { return }
        loading = true
        defer { loading = false }
        do { preview = try await source.chapters(series) } catch { app.report(error) }
    }
}

struct ChapterRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    let series: Series
    let state: ChapterState
    let inLibrary: Bool
    var selected = false
    /// (⌘ held, ⇧ held) — the series page decides what a click means.
    var onClick: (Bool, Bool) -> Void = { _, _ in }
    @State private var hover = false

    var downloading: Bool { library.downloading.contains(series.id + "|" + state.chapter.url) }
    var number: String {
        let n = state.chapter.number
        guard n >= 0 else { return "—" }
        return n == n.rounded() ? String(Int(n)) : String(n)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(number).font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(state.read ? Theme.faint : Theme.ink).frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.chapter.name).font(.system(size: 13, weight: state.read ? .regular : .medium))
                    .foregroundStyle(state.read ? Theme.dim : Theme.ink).lineLimit(1)
                if let s = state.chapter.scanlator, !s.isEmpty { Text(s).font(.meta).foregroundStyle(Theme.faint).lineLimit(1) }
            }
            Spacer(minLength: 12)
            if state.started, let n = state.pageCount {
                Text("p\(state.lastPage + 1)/\(n)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink).padding(.trailing, 14)
            }
            if inLibrary && hover {
                HStack(spacing: 12) {
                    iconButton(state.read ? "circle" : "checkmark.circle", state.read ? "Mark as unread" : "Mark as read") {
                        library.setRead(series.id, chapters: [state.chapter.url], !state.read)
                    }
                    iconButton(state.bookmarked ? "bookmark.fill" : "bookmark", state.bookmarked ? "Remove bookmark" : "Bookmark") {
                        library.setBookmarked(series.id, chapter: state.chapter.url, !state.bookmarked)
                    }
                }
                .padding(.trailing, 14)
            } else if state.bookmarked { Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.ink).padding(.trailing, 12) }
            if let d = state.chapter.uploaded {
                Text(d, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint).padding(.trailing, 14)
            }
            Group {
                if inLibrary && series.sourceID != "local" {
                    if downloading { ProgressView().controlSize(.mini) }
                    else if state.downloaded { Text("↓").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim).help("Downloaded") }
                    else {
                        Button { Task { do { try await library.download(series.id, chapter: state.chapter.url) } catch { app.report(error) } } }
                            label: { Text("↓").font(.system(size: 12, design: .monospaced)).foregroundStyle(hover ? Theme.ink : Theme.faint) }
                            .buttonStyle(.plain).help("Download for offline reading")
                    }
                }
            }
            .frame(width: 22)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1) }
        .background(selected ? Theme.surfaceHover : (hover ? Theme.surface : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            let f = NSEvent.modifierFlags
            onClick(f.contains(.command), f.contains(.shift))
        }
        .contextMenu {
            ForEach(actions) { a in Button(a.title, systemImage: a.icon, role: a.destructive ? .destructive : nil) { a.run() } }
        }
    }

    func iconButton(_ name: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: name).font(.system(size: 13)).foregroundStyle(Theme.dim).frame(width: 18, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(help)
    }

    struct Action: Identifiable { let id: String; let title: String; let icon: String; var destructive = false; let run: () -> Void }

    /// The right-click menu.
    var actions: [Action] {
        var out: [Action] = [Action(id: "read", title: "Read", icon: "play") { app.read(series, state.chapter) }]
        if inLibrary {
            out += [
                Action(id: "mark", title: state.read ? "Mark as unread" : "Mark as read", icon: state.read ? "circle" : "checkmark.circle") {
                    library.setRead(series.id, chapters: [state.chapter.url], !state.read)
                },
                Action(id: "before", title: "Mark all before as read", icon: "checkmark.circle.badge.questionmark") {
                    let prev = library.entry(series.id)?.ordered.prefix { $0.chapter.url != state.chapter.url }.map(\.chapter.url) ?? []
                    library.setRead(series.id, chapters: prev, true)
                    app.status = "Marked \(prev.count) earlier chapter\(prev.count == 1 ? "" : "s") as read."
                },
                Action(id: "beforeUnread", title: "Mark all before as unread", icon: "circle.dashed") {
                    let prev = library.entry(series.id)?.ordered.prefix { $0.chapter.url != state.chapter.url }.map(\.chapter.url) ?? []
                    library.setRead(series.id, chapters: prev, false)
                    app.status = "Marked \(prev.count) earlier chapter\(prev.count == 1 ? "" : "s") as unread."
                },
                Action(id: "bookmark", title: state.bookmarked ? "Remove bookmark" : "Bookmark", icon: state.bookmarked ? "bookmark.slash" : "bookmark") {
                    library.setBookmarked(series.id, chapter: state.chapter.url, !state.bookmarked)
                },
            ]
        }
        if series.sourceID != "local" {
            out.append(Action(id: "web", title: "View in WebView", icon: "safari") {
                app.openWeb(state.chapter.webURL ?? series.webURL, title: "\(series.title) · \(state.chapter.name)")
            })
        }
        if inLibrary && state.downloaded {
            out.append(Action(id: "undl", title: "Delete download", icon: "trash", destructive: true) {
                library.deleteDownload(series.id, chapter: state.chapter.url)
            })
        }
        return out
    }
}

/// Wrapping row layout for genre chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height); maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, w), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX, x > b.minX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

