import Foundation

// MARK: - A source backed by an installed extension

public final class ExtensionSource: Source, @unchecked Sendable {
    public let info: ExtensionSourceInfo
    let engine: ExtensionEngine
    public var id: String { "ext-" + info.id }
    public var name: String { info.displayName.isEmpty ? info.name : info.displayName }

    public init(_ info: ExtensionSourceInfo, engine: ExtensionEngine = .shared) { self.info = info; self.engine = engine }

    static let mangaFields = "id title author artist description genre status thumbnailUrl realUrl"

    func series(_ m: [String: Any]) -> Series {
        let status = SeriesStatus(engine: m["status"] as? String)
        var sr = Series(sourceID: id, url: String(describing: m["id"] ?? ""), title: m["title"] as? String ?? "",
                        author: m["author"] as? String, artist: m["artist"] as? String, summary: m["description"] as? String,
                        genres: m["genre"] as? [String] ?? [], status: status, coverURL: m["thumbnailUrl"] as? String)
        sr.webURL = (m["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return sr
    }

    private func list(_ type: String, _ page: Int, _ query: String?, filters: [SourceFilter] = []) async throws -> SeriesPage {
        var vars: [String: Any] = ["s": info.id, "p": page, "t": type]
        if let query { vars["q"] = query }
        let changes = filters.changes
        if !changes.isEmpty { vars["f"] = changes }
        let d = try await engine.q("""
            mutation($s: LongString!, $p: Int!, $t: FetchSourceMangaType!, $q: String, $f: [FilterChangeInput!]) {
              fetchSourceManga(input:{source:$s, type:$t, page:$p, query:$q, filters:$f}) { hasNextPage mangas { \(Self.mangaFields) } } }
            """, vars)
        let r = d["fetchSourceManga"] as? [String: Any] ?? [:]
        return SeriesPage(series: ((r["mangas"] as? [[String: Any]]) ?? []).map(series), hasNextPage: r["hasNextPage"] as? Bool ?? false)
    }

    public func filters() async throws -> [SourceFilter] {
        func frag(_ nested: String) -> String {
            """
            __typename
            ... on CheckBoxFilter { name cbDefault: default }
            ... on TriStateFilter { name triDefault: default }
            ... on TextFilter { name textDefault: default }
            ... on SelectFilter { name values selDefault: default }
            ... on SortFilter { name values sortDefault: default { index ascending } }
            ... on HeaderFilter { name }
            ... on SeparatorFilter { name }
            \(nested)
            """
        }
        let d = try await engine.q("query($id: LongString!) { source(id: $id) { filters { \(frag("... on GroupFilter { name filters { \(frag("")) } }")) } } }",
                                   ["id": info.id])
        let raw = ((d["source"] as? [String: Any])?["filters"] as? [[String: Any]]) ?? []
        return raw.compactMap(SourceFilter.parse)
    }

    public func preferences() async throws -> [SourcePreference] {
        let d = try await engine.q("query($id: LongString!) { source(id: $id) { preferences { \(SourcePreference.selection) } } }", ["id": info.id])
        return SourcePreference.parseAll(((d["source"] as? [String: Any])?["preferences"] as? [[String: Any]]) ?? [])
    }

    public func setPreference(_ p: SourcePreference) async throws -> [SourcePreference] {
        let d = try await engine.q("""
            mutation($s: LongString!, $c: SourcePreferenceChangeInput!) {
              updateSourcePreference(input:{source:$s, change:$c}) { preferences { \(SourcePreference.selection) } } }
            """, ["s": info.id, "c": p.change])
        return SourcePreference.parseAll(((d["updateSourcePreference"] as? [String: Any])?["preferences"] as? [[String: Any]]) ?? [])
    }

    public func search(_ query: String, filters: [SourceFilter], page: Int) async throws -> SeriesPage {
        try await list("SEARCH", page, query.isEmpty ? nil : query, filters: filters)
    }

    public func popular(page: Int) async throws -> SeriesPage { try await list("POPULAR", page, nil) }
    public func latest(page: Int) async throws -> SeriesPage { try await list("LATEST", page, nil) }
    public func search(_ query: String, page: Int) async throws -> SeriesPage { try await list("SEARCH", page, query) }

    public func details(_ s: Series) async throws -> Series {
        guard let mid = Int(s.url) else { return s }
        let d = try await engine.q("mutation($id: Int!) { fetchManga(input:{id:$id}) { manga { \(Self.mangaFields) } } }", ["id": mid])
        guard let m = (d["fetchManga"] as? [String: Any])?["manga"] as? [String: Any] else { return s }
        return series(m)
    }

    public func chapters(_ s: Series) async throws -> [Chapter] {
        guard let mid = Int(s.url) else { return [] }
        let d = try await engine.q("mutation($id: Int!) { fetchChapters(input:{mangaId:$id}) { chapters { id name chapterNumber uploadDate scanlator realUrl } } }", ["id": mid])
        let cs = ((d["fetchChapters"] as? [String: Any])?["chapters"] as? [[String: Any]]) ?? []
        return cs.map { c in
            let up = (c["uploadDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            let num = (c["chapterNumber"] as? Double).flatMap { $0 >= 0 ? $0 : nil }
            return Chapter(url: String(describing: c["id"] ?? ""), name: c["name"] as? String ?? "", number: num,
                           uploaded: (up?.timeIntervalSince1970 ?? 0) > 0 ? up : nil, scanlator: c["scanlator"] as? String,
                           webURL: (c["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    public func pages(_ c: Chapter, of s: Series) async throws -> [PageRef] {
        guard let cid = Int(c.url) else { throw FolioError("Unreadable chapter reference") }
        let d = try await engine.q("mutation($id: Int!) { fetchChapterPages(input:{chapterId:$id}) { pages } }", ["id": cid])
        let ps = ((d["fetchChapterPages"] as? [String: Any])?["pages"] as? [String]) ?? []
        guard !ps.isEmpty else { throw FolioError("The source returned no pages for \(c.name)") }
        // "engine:" refs stay valid even though the engine's port changes between launches.
        return ps.compactMap { URL(string: "engine:" + $0) }.map { .remote($0) }
    }

    public func imageData(_ page: PageRef) async throws -> Data {
        switch page {
        case .file(let u): return try Data(contentsOf: u)
        case .remote(let u):
            let s = u.absoluteString
            let path = s.hasPrefix("engine:") ? String(s.dropFirst(7)) : s
            return try await ImageFetch.data(key: "e|" + path, group: id, alias: s) { [engine] in try await engine.fetch(path) }
        }
    }

    public func coverData(_ s: Series) async throws -> Data? {
        guard let c = s.coverURL, !c.isEmpty else { return nil }
        // Covers can change upstream, so they expire after a week; pages never do.
        return try? await ImageFetch.data(key: "e|" + c, group: id, maxAge: 7 * 86400) { [engine] in try await engine.fetch(c) }
    }
}
