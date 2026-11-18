import FolioCore
import SwiftUI

/// Move a series to another source: search everywhere, pick the match, and keep your progress.
struct MigrateSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    let entry: LibraryEntry
    @StateObject private var search = GlobalSearchModel()
    @State private var query: String
    @State private var picked: Series?
    @State private var keepOriginal = false
    @State private var working = false
    @FocusState private var focused: Bool

    init(app: AppModel, entry: LibraryEntry) {
        self.app = app; self.library = app.library; self.entry = entry
        _query = State(initialValue: entry.series.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button { app.migrating = nil } label: { Text("← cancel").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain)
                Text("Migrate").font(.system(size: 30, weight: .light)).tracking(-1).foregroundStyle(Theme.ink)
                Text("Move \u{201C}\(entry.series.title)\u{201D} to another source. Read chapters, bookmarks and progress carry over.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search every source", text: $query).textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.ink)
                    .focused($focused).onSubmit { search.run(query, library: library) }
                if search.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.groups.filter { !$0.series.isEmpty }) { g in
                        Eyebrow(g.name).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 6)
                        ForEach(g.series.prefix(8)) { s in row(s, groupSource: g.id) }
                    }
                    if search.groups.isEmpty {
                        Text("Press return to search.").font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(24)
                    } else if !search.searching && search.groups.allSatisfy({ $0.series.isEmpty }) {
                        Text("No matches. Try a shorter title.").font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(24)
                    }
                }
            }

            HStack(spacing: 14) {
                HStack(spacing: 8) { MonoSwitch(isOn: $keepOriginal); Text("keep the original too").font(.system(size: 12)).foregroundStyle(Theme.dim) }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(picked.map { "Migrate to \(sourceName($0))" } ?? "Pick a match") { go() }
                    .buttonStyle(.monoLargePrimary).disabled(picked == nil || working)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 620, height: 640)
        .background(Theme.bg)
        .onAppear { focused = true; search.run(query, library: library) }
    }

    func sourceName(_ s: Series) -> String { library.source(s.sourceID)?.name ?? "source" }

    func row(_ s: Series, groupSource: String) -> some View {
        let on = picked?.id == s.id
        let same = s.id == entry.id
        return Button { if !same { picked = s } } label: {
            HStack(spacing: 12) {
                CoverView(series: s, source: library.source(s.sourceID)).frame(width: 36, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(same ? "current source" : (s.author ?? "")).font(.system(size: 11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
                if on { Text("✓").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink) }
            }
            .padding(.horizontal, 24).padding(.vertical, 7)
            .background(on ? Theme.surface : Color.clear)
            .opacity(same ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func go() {
        guard let target = picked else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let before = entry.chapters.filter(\.read).count
                let new = try await library.migrate(entry.id, to: target, keepOriginal: keepOriginal)
                let carried = new.chapters.filter(\.read).count
                app.status = "Moved to \(sourceName(target)) · \(carried) of \(before) read chapters matched."
                app.migrating = nil
                app.path = NavigationPath()
            } catch { app.report(error) }
        }
    }
}
