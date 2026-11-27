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
    @State private var readingSettings = false
    @State private var confirmBlacklist = false
    @State private var selected = Set<String>()       // chapter urls (⌘/⇧-click)
    @State private var lastClicked: String?

    var entry: LibraryEntry? { library.entry(series.id) }
    /// Full details fetched from the source on open (browse results carry only a title and cover).
    @State private var detailed: Series?
    var shown: Series {
        let base = entry?.series ?? series
        guard let d = detailed else { return base }
        var s = base       // keep identity/cover choices from the library; fill in what the source knows
        if (s.summary ?? "").isEmpty { s.summary = d.summary }
        if s.genres.isEmpty { s.genres = d.genres }
        if (s.author ?? "").isEmpty { s.author = d.author }
        if (s.artist ?? "").isEmpty { s.artist = d.artist }
        if s.status == .unknown { s.status = d.status }
        if s.webURL == nil { s.webURL = d.webURL }
        if entry == nil, s.coverURL == nil { s.coverURL = d.coverURL }
        return s
    }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .sheet(isPresented: $assigning) { AssignCategoriesSheet(library: library, seriesID: series.id) }
        .sheet(isPresented: $readingSettings) { ReadingSettingsSheet(library: library, series: shown) }
        .confirmationDialog("Blacklist \u{201C}\(shown.title)\u{201D}?", isPresented: $confirmBlacklist, titleVisibility: .visible) {
            Button("Blacklist", role: .destructive) {
                library.blacklist(shown)
                app.status = "Blacklisted \u{201C}\(shown.title)\u{201D}. Undo in Settings \u{203A} Library."
                if !app.path.isEmpty { app.path.removeLast() }
            }
        } message: {
            Text("It won\u{2019}t show up again in Browse, search, your library or history, on any source. Its downloads are deleted. You can undo this in Settings \u{203A} Library.")
        }
        .task { await loadDetails() }
        .task {
            await loadPreview()
            // Library entries saved before web addresses were remembered: fetch them once.
            if let e = entry, series.sourceID != "local", e.series.webURL == nil { _ = try? await library.refresh(e.id) }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(app.fullPage ? .hidden : .visible, for: .windowToolbar)
    }

    var header: some View {
        HStack(alignment: .top, spacing: 28) {
            CoverView(series: shown, source: source, corner: 3).frame(width: 112)
            VStack(alignment: .leading, spacing: 12) {
                Text(shown.title).font(.system(size: 32, weight: .light)).tracking(-0.9)
                    .foregroundStyle(Theme.ink).lineLimit(3).textSelection(.enabled)
                byline
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
        HStack(spacing: 20) {
            Text("\(selected.count) selected").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            Button("Mark read") { library.setRead(series.id, chapters: Array(selected), true); selected = [] }
            Button("Mark unread") { library.setRead(series.id, chapters: Array(selected), false); selected = [] }
            Spacer()
            Button("Clear") { selected = [] }
        }
        .buttonStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Theme.dim)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    /// Author (and artist when different) · status · source.
    var byline: some View {
        let people: String? = {
            let a = (shown.author ?? "").trimmingCharacters(in: .whitespaces)
            let r = (shown.artist ?? "").trimmingCharacters(in: .whitespaces)
            if a.isEmpty { return r.isEmpty ? nil : r }
            if r.isEmpty || r.caseInsensitiveCompare(a) == .orderedSame { return a }
            return "\(a) · art by \(r)"
        }()
        return Text([people, shown.status == .unknown ? nil : shown.status.label, source?.name].compactMap { $0 }.joined(separator: "   ·   "))
            .font(.system(size: 14)).foregroundStyle(Theme.dim).textSelection(.enabled)
    }

    /// Facts drawn from the chapter list.
    var facts: [(String, String)] {
        let all = entry?.chapters.map(\.chapter) ?? preview
        var out: [(String, String)] = []
        if !all.isEmpty { out.append(("Chapters", "\(all.count)")) }
        if let latest = all.compactMap(\.uploaded).max() {
            out.append(("Last update", latest.formatted(date: .abbreviated, time: .omitted)))
        }
        var seen = Set<String>()
        let groups = all.compactMap(\.scanlator).flatMap { $0.split(separator: "&").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        if !groups.isEmpty {
            out.append(("Scanlation", groups.prefix(4).joined(separator: ", ") + (groups.count > 4 ? " +\(groups.count - 4)" : "")))
        }
        return out
    }

    @ViewBuilder var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = shown.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                Text(d).font(.system(size: 14.5)).foregroundStyle(Theme.dim).lineSpacing(5)
                    .lineLimit(expanded ? nil : 4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if d.count > 420 {
                    Button(expanded ? "Show less" : "Show more") { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                        .buttonStyle(.plain).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                }
            } else if detailed == nil && entry == nil {
                Text("Loading details…").font(.system(size: 13.5)).foregroundStyle(Theme.faint)
            }
            if !shown.genres.isEmpty {
                FlowLayout(spacing: 7) {
                    ForEach(shown.genres, id: \.self) { g in
                        Text(g).font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Theme.line))
                            .contextMenu { Button("Search All Sources for \u{201C}\(g)\u{201D}") { app.searchEverywhere(g) } }
                    }
                }
            }
            let f = facts
            if !f.isEmpty {
                HStack(alignment: .top, spacing: 34) {
                    ForEach(f, id: \.0) { k, v in
                        VStack(alignment: .leading, spacing: 3) {
                            Eyebrow(k)
                            Text(v).font(.system(size: 13.5)).foregroundStyle(Theme.ink).lineLimit(2).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    var chapterBar: some View {
        HStack(spacing: 18) {
            Text("\(rows.count) chapters").font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            if let e = entry, e.unread > 0 {
                Text("\(e.unread) unread").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            Spacer()
            if entry != nil {
                Menu {
                    Toggle("Unread", isOn: $onlyUnread)
                    Toggle("Downloaded", isOn: $onlyDownloaded)
                    Toggle("Bookmarked", isOn: $onlyBookmarked)
                } label: {
                    Text({ let n = [onlyUnread, onlyDownloaded, onlyBookmarked].filter { $0 }.count; return n > 0 ? "filter · \(n)" : "filter" }())
                        .font(.system(size: 13.5, design: .monospaced)).foregroundStyle(onlyUnread || onlyDownloaded || onlyBookmarked ? Theme.ink : Theme.dim)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let e = entry {
                Button { Task { do { let n = try await library.refresh(e.id); app.status = n == 0 ? "No new chapters." : "\(n) new." } catch { app.report(error) } } }
                    label: { Text("refresh").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain).help("Check for new chapters")
            }
            Button { newestFirst.toggle() } label: {
                Text(newestFirst ? "newest ↓" : "oldest ↑").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.dim)
            }.buttonStyle(.plain)
        }
    }

    /// Save · Read · extras, in one row.
    @ViewBuilder var actions: some View {
        HStack(spacing: 10) {
            // One toggle, icon only: filled = in your library.
            Button { Task { await app.toggleSaved(shown) } } label: {
                Image(systemName: saved ? "bookmark.fill" : "bookmark").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(saved ? Theme.ink : Theme.dim)
                    .frame(width: 18)
            }
            .buttonStyle(.monoLarge)
            .help(saved ? "In your library. Click to remove." : "Add to your library")
            .accessibilityLabel(saved ? "Remove from library" : "Add to library")
            if let e = entry, !e.chapters.isEmpty {
                Button { app.resume(e) } label: {
                    HStack(spacing: 9) {
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
            if let e = entry, series.sourceID != "local" {      // local files are already on this Mac
                Menu { DownloadMenuItems(library: library, entry: e) } label: { Text("Download") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.mono).fixedSize()
                    .disabled(!saved)
                    .help(saved ? "Download chapters" : "Add to your library to download")
            }
            // Available whether or not the series is in your library.
            Menu {
                Button("Search All Sources for \u{201C}\(shown.title)\u{201D}") { app.searchEverywhere(shown.title) }
                Button("Reading Settings…") { readingSettings = true }
                if saved { Button("Categories…") { assigning = true } }
                if let e = entry {
                    Divider()
                    Button("Mark All as Read") { library.markAll(e.id, read: true) }.disabled(e.unread == 0)
                    Button("Mark All as Unread") { library.markAll(e.id, read: false) }
                }
                if series.sourceID != "local" {
                    Divider()
                    if saved, let e = entry { Button("Migrate to Another Source…") { app.migrating = e } }
                    Button("View in WebView") { app.openWeb(shown.webURL, title: shown.title) }
                    if let u = shown.webURL, !u.isEmpty {
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string)
                            app.status = "Link copied."
                        }
                    }
                }
                Divider()
                Button("Blacklist…", role: .destructive) { confirmBlacklist = true }
            } label: { Text("···") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.mono).fixedSize()
        }
    }

    /// Always ask the source for the full description, tags, authors and status. A saved series that's missing
    /// them is refreshed so the library keeps them too.
    func loadDetails() async {
        guard let source, series.sourceID != "local" || (shown.summary ?? "").isEmpty else { return }
        if let e = entry, !(e.series.summary ?? "").isEmpty, !e.series.genres.isEmpty { return }
        if let d = try? await source.details(series) { detailed = d }
        if let e = entry, (e.series.summary ?? "").isEmpty || e.series.genres.isEmpty { _ = try? await library.refresh(e.id) }
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
    /// Waiting in the download queue (not started yet).
    var queued: Bool {
        let k = series.id + "|" + state.chapter.url
        return library.downloadJobs.contains { $0.key == k && $0.state == .queued }
    }
    var number: String {
        let n = state.chapter.number
        guard n >= 0 else { return "—" }
        return n == n.rounded() ? String(Int(n)) : String(n)
    }

    /// True when the title already carries the chapter number ("Chapter 3", "Ch. 3.5").
    var nameHasNumber: Bool {
        guard state.chapter.number >= 0 else { return false }
        let tokens = state.chapter.name.split { !($0.isNumber || $0 == ".") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return tokens.contains { Double($0) == state.chapter.number }
    }

    var body: some View {
        HStack(spacing: 0) {
            if !nameHasNumber {
                Text(number).font(.system(size: 14.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(state.read ? Theme.faint : Theme.ink).frame(width: 54, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.chapter.name).font(.system(size: 14.5, weight: state.read ? .regular : .medium))
                    .foregroundStyle(state.read ? Theme.dim : Theme.ink).lineLimit(1)
                if let s = state.chapter.scanlator, !s.isEmpty { Text(s).font(.meta).foregroundStyle(Theme.faint).lineLimit(1) }
            }
            Spacer(minLength: 12)
            if state.started, let n = state.pageCount {
                Text("p\(state.lastPage + 1)/\(n)").font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink).padding(.trailing, 14)
            }
            if inLibrary && hover {
                HStack(spacing: 15) {
                    iconButton(state.read ? "circle" : "checkmark.circle", state.read ? "Mark as unread" : "Mark as read") {
                        library.setRead(series.id, chapters: [state.chapter.url], !state.read)
                    }
                    iconButton(state.bookmarked ? "bookmark.fill" : "bookmark", state.bookmarked ? "Remove bookmark" : "Bookmark") {
                        library.setBookmarked(series.id, chapter: state.chapter.url, !state.bookmarked)
                    }
                }
                .padding(.trailing, 14)
            } else if state.bookmarked { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(Theme.ink).padding(.trailing, 12) }
            if let d = state.chapter.uploaded {
                Text(d, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.faint).padding(.trailing, inLibrary && series.sourceID != "local" ? 14 : 0)
            }
            if inLibrary && series.sourceID != "local" {
              Group {
                    if downloading { ProgressView().controlSize(.mini) }
                    else if queued { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.faint).help("Queued for download") }
                    else if state.downloaded { Text("↓").font(.system(size: 13.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.dim).help("Downloaded") }
                    else {
                        Button { library.enqueueDownloads(series.id, chapters: [state.chapter.url]) }
                            label: { Text("↓").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(hover ? Theme.ink : Theme.faint) }
                            .buttonStyle(.plain).help("Download for offline reading")
                    }
              }
              .frame(width: 22, alignment: .trailing)
            }
        }
        .padding(.vertical, 12)
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
        Button(action: run) { Image(systemName: name).font(.system(size: 14.5)).foregroundStyle(Theme.dim).frame(width: 18, height: 18).contentShape(Rectangle()) }
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

