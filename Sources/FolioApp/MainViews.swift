import FolioCore
import SwiftUI

struct RootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library

    init(app: AppModel) { self.app = app; self.library = app.library }

    var body: some View {
        ZStack {
            content
            if let r = app.reader {
                ReaderView(model: r).id(ObjectIdentifier(r)).transition(.opacity).zIndex(1)
            }
            if !library.settings.setupDone {
                SetupView(app: app, library: library).transition(.opacity).zIndex(5)
            }
            LockOverlay(model: app.lock).zIndex(10)
        }
        .frame(minWidth: 760, minHeight: 520)      // SwiftUI resets the window's own minimum, so the content states it
        .background(Theme.bg)
        .tint(Theme.ink)
        .sheet(item: $app.migrating) { e in MigrateSheet(app: app, entry: e) }
        .alert("Your library couldn\u{2019}t be read", isPresented: .constant(library.loadProblem != nil)) {
            Button("Quit and keep the file") { NSApp.terminate(nil) }
            Button("Start with an empty library", role: .destructive) { library.startFresh() }
        } message: {
            Text((library.loadProblem ?? "") + " Quit to repair it by hand or restore a backup; starting empty leaves the copy on disk.")
        }
    }

    var content: some View {
        HStack(spacing: 0) {
            if app.reader == nil {
                Sidebar(app: app, library: library)
                Rectangle().fill(Theme.line).frame(width: 1)
            }
            stack
        }
    }

    var stack: some View {
        NavigationStack(path: $app.path) {
            Group {
                switch app.sidebar ?? .library {
                case .search: LibraryView(app: app, library: library)
                case .library: LibraryView(app: app, library: library)
                case .recents: RecentsView(app: app, library: library)
                case .sources, .extensions, .source: SourcesView(app: app, library: library)
                case .settings: SettingsView(app: app, library: library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)     // pages start at the top, however tall the window
            .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
            .navigationDestination(for: Series.self) {
                SeriesView(app: app, library: library, series: $0)
                    .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
            }
            .navigationDestination(for: SourceRoute.self) { route in
                Group {
                    switch route {
                    case .extensions: ExtensionsView(app: app, model: app.extensions, library: library)
                    case .browse(let id):
                        if let src = library.source(id) { BrowseView(app: app, source: src).id(id) }
                        else { ContentUnavailableView("Source removed", systemImage: "questionmark.folder") }
                    }
                }
                .navigationBarBackButtonHidden(true)     // the page has its own BackLink; the title bar stays empty
                .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
            }
            .navigationDestination(for: SettingsPage.self) { SettingsPageView(app: app, library: library, page: $0) }
        }
        .toolbarBackground(Theme.bg, for: .windowToolbar)         // a solid, fixed bar: content scrolls beneath it, never through it
        .toolbarBackground(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
        .overlay(alignment: .bottom) { Banner(app: app) }
        .onChange(of: app.sidebar) { _, new in
            // `.extensions` / `.source(id)` stay usable as shorthand: show Sources and push the page.
            switch new {
            case .extensions?: app.sidebar = .sources; app.path = NavigationPath([SourceRoute.extensions])
            case .source(let id)?: app.sidebar = .sources; app.path = NavigationPath([SourceRoute.browse(id)])
            case .sources?: break      // keeps a route we just pushed
            default: app.path = NavigationPath()
            }
        }
        .onChange(of: library.settings.appearance) { _, _ in app.applyAppearance() }
    }
}

// MARK: - Sidebar: app navigation lives in the content, not the title bar

/// Pages pushed from Sources, so their back stack matches every other page.
enum SourceRoute: Hashable { case browse(String), extensions }

struct Sidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var queueOpen = false

    var current: SidebarItem { app.sidebar ?? .library }
    /// Sources stays lit while you're inside one of its pages.
    var inSources: Bool {
        switch current { case .sources, .extensions, .source: true; default: false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(spacing: 10) {
                FolioMark().frame(width: 132)
                Text(".folio").font(.system(size: 24, weight: .bold, design: .monospaced)).tracking(-0.8).foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6).padding(.bottom, 22)
            row("Library", "books.vertical", .library, on: current == .library || current == .search)
            row("Recent", "clock", .recents, on: current == .recents)
            row("Sources", "square.stack.3d.up", .sources, on: inSources)
            row("Settings", "gearshape", .settings, on: current == .settings)
            Spacer()
            if library.downloadsPending > 0 {
                Button { queueOpen.toggle() } label: {
                    Label("Downloading · \(library.downloadsPending)", systemImage: "arrow.down.circle")
                        .font(.system(size: 13.5)).foregroundStyle(Theme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $queueOpen, arrowEdge: .trailing) { DownloadQueue(library: library) }
            }
            if library.settings.incognito {
                Button { library.settings.incognito = false } label: {
                    Label("Incognito", systemImage: "eye.slash").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.onInk).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.ink, in: Capsule())
                }
                .buttonStyle(.plain).padding(.leading, 6)
                .help("Nothing you read is recorded. Click to turn off.")
            }
        }
        .padding(.horizontal, 10).padding(.top, 44).padding(.bottom, 14)
        .frame(width: 188).frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
    }

    func row(_ title: String, _ icon: String, _ item: SidebarItem, on: Bool) -> some View {
        Button { app.sidebar = item; app.path = NavigationPath() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14.5)).frame(width: 18)
                Text(title).font(.system(size: 14.5, weight: on ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(on ? Theme.ink : Theme.dim)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Clicking the queue indicator shows it; cancelling is a separate, explicit button.
struct DownloadQueue: View {
    @ObservedObject var library: Library
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloads").font(.system(size: 14.5, weight: .semibold))
            Text("\(library.downloadsPending) chapter\(library.downloadsPending == 1 ? "" : "s") queued or downloading")
                .font(.system(size: 13.5)).foregroundStyle(Theme.dim)
            Button("Cancel all", role: .destructive) { library.cancelDownloads() }
        }
        .padding(16).frame(minWidth: 220, alignment: .leading)
    }
}


// MARK: - Sources: everything you can read from, in one list

struct SourcesView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sources").font(.system(size: 36, weight: .light)).tracking(-1).foregroundStyle(Theme.ink)
                }
                .padding(.top, 8).padding(.bottom, 18)

                SourceRow(name: "Extensions", detail: library.visibleExtensionSources.isEmpty ? "add some" : "manage",
                          icon: { Image(systemName: "puzzlepiece.extension").font(.system(size: 13.5)) }) { app.path.append(SourceRoute.extensions) }
                if library.visibleExtensionSources.isEmpty {
                    Text("No extensions installed. Open Extensions to add a repo and install sources.")
                        .font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.faint).padding(.vertical, 16)
                }
                ForEach(library.visibleExtensionSources, id: \.id) { s in
                    SourceRow(name: s.name, detail: s.info.lang, icon: { SourceIcon(source: s) }) { app.path.append(SourceRoute.browse(s.id)) }
                }

                if !library.settings.servers.isEmpty {
                    Eyebrow("Servers").padding(.top, 34).padding(.bottom, 4)
                    ForEach(library.settings.servers) { sv in
                        SourceRow(name: sv.name, detail: "opds", icon: { Image(systemName: "server.rack").font(.system(size: 13.5)) }) {
                            app.path.append(SourceRoute.browse("opds-" + sv.id))
                        }
                    }
                }

                Eyebrow("On this Mac").padding(.top, 34).padding(.bottom, 4)
                SourceRow(name: "Local files", detail: ".cbz · .zip · folders", icon: { Image(systemName: "folder").font(.system(size: 13.5)) }) {
                    app.path.append(SourceRoute.browse("local"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pad).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SourceRow<Icon: View>: View {
    let name: String
    let detail: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                icon().frame(width: 20, height: 20).foregroundStyle(Theme.dim)
                Text(name).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 12)
                Text(detail).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.faint)
                Text("→").font(.system(size: 15.5, design: .monospaced)).foregroundStyle(hover ? Theme.ink : Theme.faint)
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .background(hover ? Theme.surface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}


struct SourceIcon: View {
    let source: ExtensionSource
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().clipShape(RoundedRectangle(cornerRadius: 4)) }
            else { Image(systemName: "puzzlepiece.extension").font(.system(size: 13.5)) }
        }
        .task(id: source.info.iconPath) {
            guard let p = source.info.iconPath, ExtensionEngine.shared.state == .running else { return }
            icon = await Images.shared.image("exticon|" + p, maxWidth: 64, priority: .low) { try await ExtensionEngine.shared.fetch(p) }
        }
    }
}

struct Banner: View {
    @ObservedObject var app: AppModel
    var body: some View {
        VStack(spacing: 8) {
            if let e = app.error { msg(e, "exclamationmark.circle", autoHide: false) { app.error = nil } }     // errors stay until dismissed
            if let s = app.status { msg(s, "checkmark.circle", autoHide: true) { app.status = nil } }
        }
        .padding()
        .animation(.easeOut(duration: 0.18), value: app.error)
        .animation(.easeOut(duration: 0.18), value: app.status)
    }

    func msg(_ t: String, _ icon: String, autoHide: Bool, close: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.ink)
            Text(t).font(.system(size: 14)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .task { if autoHide { try? await Task.sleep(for: .seconds(6)); close() } }
    }
}

// MARK: cover + grid

/// Flat placeholder: initials on a quiet surface. No gradients, nothing to composite.
struct CoverPlaceholder: View {
    let title: String
    var body: some View {
        ZStack {
            Theme.surface
            Text(title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.faint)
                .lineLimit(1).minimumScaleFactor(0.3).padding(.horizontal, 2)
        }
    }
}

struct CoverView: View {
    let series: Series
    let source: Source?
    var corner: CGFloat = Theme.coverRadius
    var highlight = false
    @State private var image: NSImage?

    init(series: Series, source: Source?, corner: CGFloat = Theme.coverRadius, highlight: Bool = false) {
        self.series = series; self.source = source; self.corner = corner; self.highlight = highlight
        // Already decoded (scrolled back to it, or prefetched)? Show it on the very first frame.
        _image = State(initialValue: MainActor.assumeIsolated { Images.shared.cached(Images.coverKey(series)) })
    }

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {   // the image fills a fixed 2:3 frame and is cropped, whatever its own shape
                if let image { Image(nsImage: image).resizable().scaledToFill() } else { CoverPlaceholder(title: series.title) }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(highlight ? Theme.dim : Theme.line))
            .task(id: series.coverURL) {
                guard image == nil else { return }
                let img = await Images.shared.cover(series, source: source)
                withAnimation(.easeOut(duration: 0.15)) { image = img }
            }
    }
}

struct SeriesCard: View {
    let series: Series
    let source: Source?
    var badge: Int = 0
    var downloaded: Int = 0
    var inLibrary = false
    var progress: Double? = nil
    var compact = false
    var titles: CardTitles = .below
    var isNew = false
    /// When set, a bookmark button appears on hover (and stays while saved) to save/unsave.
    var onToggleSave: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(series: series, source: source, highlight: hover)
                .overlay(alignment: .bottomTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.onInk)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.ink, in: RoundedRectangle(cornerRadius: 2))
                            .overlay { if isNew { RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.onInk.opacity(0.9), lineWidth: 1.5).padding(1) } }   // "new" folds into the unread count
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if downloaded > 0 {
                        Text("↓\(downloaded)").font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 2))
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottom) {
                    if titles == .hover && hover {
                        Text(series.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.black.opacity(0.82))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if inLibrary || (hover && onToggleSave != nil) {
                        Image(systemName: inLibrary ? "bookmark.fill" : "bookmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(inLibrary ? Theme.onInk : Theme.ink)
                            .frame(width: 20, height: 20)
                            .background(inLibrary ? Theme.ink.opacity(0.85) : Color.black.opacity(0.7), in: Circle())
                            .overlay(Circle().strokeBorder(inLibrary ? Color.clear : Color.white.opacity(0.25)))
                            .padding(6)
                            .contentShape(Circle())
                            .onTapGesture { onToggleSave?() }
                            .help(inLibrary ? "In your library. Click to remove." : "Save to library")
                    }
                }
            Hairline(value: progress ?? 0).padding(.horizontal, 1).opacity(progress == nil ? 0 : 1)     // always reserve the row: titles share a baseline
            if titles == .below {
                Text(series.title).font(.system(size: 13, weight: .medium)).foregroundStyle(hover ? Theme.ink : Theme.dim)
                    .lineLimit(1).multilineTextAlignment(.leading)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

let gridColumns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 14, alignment: .top)]

struct RecentsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var confirmClear = false

    var groups: [(String, [LibraryEntry])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateStyle = .medium
        var out: [(String, [LibraryEntry])] = []
        for e in library.recents {
            let d = e.lastRead ?? .distantPast
            let key = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : f.string(from: d)
            if out.last?.0 == key { out[out.count - 1].1.append(e) } else { out.append((key, [e])) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    Text("Recent").font(.system(size: 36, weight: .light)).tracking(-1).foregroundStyle(Theme.ink)
                    Spacer()
                    Menu {
                        Button("Older than 1 hour") { library.clearHistory(olderThan: 3600); app.status = "Cleared history older than an hour." }
                        Button("Older than 1 day") { library.clearHistory(olderThan: 86400); app.status = "Cleared history older than a day." }
                        Divider()
                        Button("Everything…", role: .destructive) { confirmClear = true }
                    } label: { Text("clear").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.dim) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(library.recents.isEmpty)
                    .help("Your place in each series is kept.")
                }
                .padding(.top, 8)
                .confirmationDialog("Clear all reading history?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear All History", role: .destructive) { library.clearHistory(); app.status = "History cleared." }
                }
                if library.recents.isEmpty {
                    Text("Nothing read yet. Series you read show up here.")
                        .font(.system(size: 15.5)).foregroundStyle(Theme.dim).padding(.top, 28)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { g in
                        Eyebrow(g.0).padding(.top, 28).padding(.bottom, 4)
                        ForEach(g.1) { e in RecentRow(app: app, library: library, entry: e) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.pad).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecentRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    let entry: LibraryEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 18) {
            CoverView(series: entry.series, source: library.source(entry.series.sourceID), corner: 3).frame(width: 46)
            Text(entry.series.title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            if entry.isSaved { Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Theme.dim).help("In your library") }
            if let c = entry.resumeChapter {
                Text(c.started ? "\(c.chapter.name) · p\(c.lastPage + 1)\(c.pageCount.map { "/\($0)" } ?? "")"
                               : (c.read ? "finished \(c.chapter.name)" : "next: \(c.chapter.name)"))
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let d = entry.lastRead {
                Text(d, format: .dateTime.hour().minute()).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.faint)
            }
            Button { app.path.append(entry.series) } label: {
                Text("details").font(.system(size: 13, design: .monospaced)).foregroundStyle(hover ? Theme.dim : Theme.faint)
            }
            .buttonStyle(.plain).help("Open the series page")
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .background(hover ? Theme.surface : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.resume(entry) }      // the point of Recent is to carry on
        .contextMenu {
            Button("Series details", systemImage: "info.circle") { app.path.append(entry.series) }
            Button(entry.isSaved ? "Remove from Library" : "Save to Library", systemImage: entry.isSaved ? "bookmark.slash" : "bookmark") {
                Task { await app.toggleSaved(entry.series) }
            }
            Button("Remove from History", systemImage: "clock.badge.xmark") { library.forget(entry.id) }
        }
    }
}

/// One line: series, where you are, and an arrow. Click to carry on.
struct ContinueCard: View {
    @ObservedObject var app: AppModel
    let entry: LibraryEntry
    @State private var hover = false

    var body: some View {
        HStack(spacing: 18) {
            Text(entry.series.title).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
            if let c = entry.resumeChapter {
                Text(c.started ? "\(c.chapter.name) · p\(c.lastPage + 1)" : c.chapter.name)
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Text("→").font(.system(size: 15.5, design: .monospaced)).foregroundStyle(hover ? Theme.ink : Theme.faint)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.resume(entry) }
    }
}

struct SectionTitle: View {
    let text: String
    var count: Int? = nil
    init(_ text: String, count: Int? = nil) { self.text = text; self.count = count }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.ink).tracking(-1)
            if let count { Text("\(count)").font(.system(size: 13.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.faint).baselineOffset(14) }
        }
    }
}

func ago(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: browse a source

struct BrowseView: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var library: Library      // so the saved marks update the moment you save
    let source: Source
    @State private var results: [Series] = []
    @State private var savedAtLoad = Set<String>()     // series that were already saved when their page arrived (new saves stay put until reload)
    @State private var seen = Set<String>()
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var latest: Bool
    @State private var furthest = 0          // furthest card index that has been on screen
    @State private var generation = 0        // bumps on every reset so stale loads are dropped
    @State private var filters: [SourceFilter] = []       // being edited in the panel
    @State private var applied: [SourceFilter] = []       // what the list is currently using
    @State private var showFilters = false
    @State private var showPrefs = false
    @State private var prefsDirty = false
    var ext: ExtensionSource? { source as? ExtensionSource }

    /// How many series to keep loaded beyond the furthest one you've scrolled to.
    static let ahead = 150

    init(app: AppModel, source: Source) {
        self.app = app
        self.library = app.library
        self.source = source
        _latest = State(initialValue: (source as? ExtensionSource)?.info.supportsLatest ?? false)   // open on Newest
    }

    var body: some View {
        ScrollView {
            browseHeader
            LazyVGrid(columns: gridColumns, spacing: 18) {
                ForEach(Array(shownResults.enumerated()), id: \.element.id) { i, s in
                    NavigationLink(value: s) {
                        SeriesCard(series: s, source: source, inLibrary: app.library.contains(s), onToggleSave: { Task { await app.toggleSaved(s) } })
                    }
                    .buttonStyle(.plain)
                    .contextMenu { BlacklistMenuItem(app: app, series: s) }
                    .onAppear { if i > furthest { furthest = i; Task { await fillAhead() } } }
                }
            }
            .padding(Theme.pad)
            if hasMore && !results.isEmpty {
                // End-of-list sentinel: coming into view always pulls in the next pages.
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Loading more…").foregroundStyle(Theme.dim) }
                    .font(.callout).frame(maxWidth: .infinity).padding(.vertical, 28)
                    .onAppear { furthest = max(furthest, results.count); Task { await fillAhead() } }
                    .id("sentinel-\(results.count)")
            } else if !hasMore && !shownResults.isEmpty {
                Text("End of results").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.pad).padding(.bottom, 28)
            }
            if !loading && shownResults.isEmpty && !(hasMore && !results.isEmpty) {
                ContentUnavailableView {
                    Label(!results.isEmpty ? "Everything here is already saved" : (activeQuery.isEmpty ? "Nothing here yet" : "No results"), systemImage: "magnifyingglass")
                } description: {
                    if source.id == "local" && activeQuery.isEmpty {
                        Text("Import folders or .cbz/.zip files. Each folder is a series; its subfolders or archives are chapters.")
                    }
                } actions: {
                    if source.id == "local" { Button("Import Files…") { app.importLocal() } }
                }
                .padding(.top, 60)
            }
        }
        .overlay { if loading && results.isEmpty { ProgressView().controlSize(.large) } }
        .navigationTitle(source.name)
        .navigationSubtitle(activeQuery.isEmpty ? (applied.activeCount > 0 ? "Filtered" : (latest ? "Newest" : "Popular")) : "Results for “\(activeQuery)”")
        .toolbar(app.reader == nil ? .visible : .hidden, for: .windowToolbar)
        .onChange(of: query) { _, q in if q.isEmpty && !activeQuery.isEmpty { activeQuery = ""; Task { await reset() } } }
        .task { if results.isEmpty { await reset() } }
        .task {
            if filters.isEmpty, let f = try? await source.filters() { filters = f }
            if DebugHook.enabled, filters.isEmpty, source.id == "local" { filters = DebugHook.demoFilters }
        }
        .onChange(of: showPrefs) { _, open in if !open && prefsDirty { prefsDirty = false; Task { await reset() } } }     // a setting changed what the source returns
        .onChange(of: app.debugFilterPanel) { _, v in showFilters = v }
    }

    /// The page's own title and tools — kept out of the titlebar, which is for navigation only.
    var browseHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            BackLink(title: "Sources") { if !app.path.isEmpty { app.path.removeLast() } }
            browseTitleRow
        }
        .padding(.horizontal, Theme.pad).padding(.top, 8)
    }

    var browseTitleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Text(source.name).font(.system(size: 36, weight: .light)).tracking(-1).foregroundStyle(Theme.ink).lineLimit(1)
            if !activeQuery.isEmpty {
                Text("“\(activeQuery)”").font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 12)
            MonoField(placeholder: "Search \(source.name)", text: $query, width: 200)
                .onSubmit { activeQuery = query; Task { await reset() } }
            if let ext, ext.info.supportsLatest, activeQuery.isEmpty, applied.activeCount == 0 {
                Picker("", selection: Binding(get: { latest }, set: { v in if v != latest { latest = v; Task { await reset() } } })) {
                    Text("Newest").tag(true)
                    Text("Popular").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            toolTab("hide saved", on: app.library.settings.hideSavedInBrowse) {
                app.library.settings.hideSavedInBrowse.toggle()
                if app.library.settings.hideSavedInBrowse {
                    savedAtLoad = Set(results.filter { app.library.contains($0) }.map(\.id))
                    furthest = max(furthest, results.count)
                    Task { await fillAhead() }
                }
            }
            .help("Only show series that aren't in your library yet")
            if source.id == "local" { toolTab("import", on: false) { app.importLocal() } }
            if !filters.isEmpty {
                toolTab(applied.activeCount > 0 ? "filters · \(applied.activeCount)" : "filters", on: applied.activeCount > 0 || showFilters) { showFilters.toggle() }
                    .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                        FilterPanel(filters: $filters) { applied = filters; showFilters = false; Task { await reset() } }
                    }
            }
            if let ext, ext.info.isConfigurable ?? true {
                toolTab("settings", on: showPrefs) { showPrefs.toggle() }
                    .popover(isPresented: $showPrefs, arrowEdge: .bottom) { PrefsPanel(source: ext) { prefsDirty = true } }
            }
        }
    }

    func toolTab(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 13.5, weight: on ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(on ? Theme.ink : Theme.dim)
                .overlay(alignment: .bottom) { if on { Rectangle().fill(Theme.ink).frame(height: 1.5).offset(y: 4) } }
        }
        .buttonStyle(.plain)
    }

    /// With "hide saved" on, series that were already in the library are left out.
    var shownResults: [Series] {
        let r = results.filter { !app.library.isBlacklisted($0) }      // blacklisted series never show up
        return app.library.settings.hideSavedInBrowse ? r.filter { !savedAtLoad.contains($0.id) } : r
    }

    func reset() async {
        generation += 1
        results = []; seen = []; savedAtLoad = []; page = 0; hasMore = true; furthest = 0
        await fillAhead()
    }

    /// Keeps fetching pages until there are `ahead` series beyond what you've scrolled to,
    /// and fetches their covers in the background so they're ready before they're on screen.
    func fillAhead() async {
        guard !loading else { return }
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        while hasMore, results.count < furthest + Self.ahead, gen == generation, !Task.isCancelled {
            let p = page + 1
            do {
                let r: SeriesPage
                if !activeQuery.isEmpty || applied.activeCount > 0 { r = try await source.search(activeQuery, filters: applied, page: p) }
                else if latest, let ext { r = try await ext.latest(page: p) }
                else { r = try await source.popular(page: p) }
                guard gen == generation else { return }
                let fresh = r.series.filter { seen.insert($0.id).inserted }
                results += fresh
                for s in fresh where library.contains(s) { savedAtLoad.insert(s.id) }
                page = p
                // A page with nothing new ends it: some sites repeat the last page forever, which would otherwise
                // turn into an endless run of requests.
                hasMore = r.hasNextPage && !fresh.isEmpty
                prefetchCovers(fresh)
            } catch {
                if AppModel.isCancellation(error) { return }      // the screen went away; a later visit continues
                if gen == generation { hasMore = false; app.report(error) }
                return
            }
        }
    }

    func prefetchCovers(_ items: [Series]) {
        let src = source
        Task(priority: .utility) {
            for s in items { _ = await Images.shared.cover(s, source: src) }
        }
    }
}


/// "Blacklist" for a cover's right-click menu: hides the series everywhere at once; undo in Settings › Library.
struct BlacklistMenuItem: View {
    @ObservedObject var app: AppModel
    let series: Series
    var body: some View {
        Divider()
        Button("Blacklist \u{201C}\(series.title)\u{201D}", role: .destructive) {
            app.library.blacklist(series)
            app.status = "Blacklisted \u{201C}\(series.title)\u{201D}. Undo in Settings \u{203A} Library."
        }
    }
}
