import Foundation

extension ExtensionEngine {
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var _baseForTesting: URL { base }
    public func _queryForTesting(_ q: String, _ v: [String: Any] = [:]) async throws -> [String: Any] { try await self.q(q, v) }

    func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        r.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return r
    }

    func graphql(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        var r = request("/api/graphql")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 90
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (d, resp) = try await URLSession.folioLocal.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw FolioError("Extension engine error (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        if let errs = j["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String {
            if CloudflareError.matches(m) { throw CloudflareError() }
            throw FolioError(m.count > 300 ? String(m.prefix(300)) + "…" : m)
        }
        return j["data"] as? [String: Any] ?? [:]
    }

    /// GraphQL once the engine is up.
    func q(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        try await ensureRunning()
        return try await graphql(query, variables)
    }

    public func fetch(_ path: String) async throws -> Data {
        try await ensureRunning()
        let (d, h) = try await Net.data(for: request(path), session: .folioLocal)
        guard (200..<300).contains(h.statusCode) else {
            if CloudflareError.matches(String(decoding: d.prefix(2048), as: UTF8.self)) { throw CloudflareError("HTTP \(h.statusCode)") }
            throw FolioError("Couldn't load image (HTTP \(h.statusCode))")
        }
        return d
    }
}

extension ExtensionEngine {
    /// Restores a `.tachibk` / `.proto.gz` backup through the engine (which reads Tachiyomi's format
    /// natively), then returns what it put in its library. `progress` reports (done, total).
    public func importTachiyomiBackup(_ file: Data, name: String = "backup.tachibk",
                                      progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [ImportedSeries] {
        try await ensureRunning()
        let boundary = "folio-" + UUID().uuidString
        let ops = #"{"query":"mutation($file: Upload!) { restoreBackup(input:{backup:$file}) { id } }","variables":{"file":null}}"#
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"operations\"\r\n\r\n\(ops)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"map\"\r\n\r\n{\"0\":[\"variables.file\"]}\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"0\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(file)
        add("\r\n--\(boundary)--\r\n")
        var r = request("/api/graphql")
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 120
        r.httpBody = body
        let (d, resp) = try await URLSession.folioLocal.data(for: r)
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        if let m = ((j["errors"] as? [[String: Any]])?.first?["message"]) as? String { throw FolioError("Couldn\u{2019}t read that backup: \(m)") }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let id = (((j["data"] as? [String: Any])?["restoreBackup"]) as? [String: Any])?["id"] as? String else {
            throw FolioError("The engine couldn\u{2019}t start the import.")
        }
        // Poll until the engine reports it is done.
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(500))
            let s = try await graphql("query($id: String!) { restoreStatus(id: $id) { state mangaProgress totalManga } }", ["id": id])
            let st = s["restoreStatus"] as? [String: Any] ?? [:]
            let state = st["state"] as? String ?? ""
            progress?(st["mangaProgress"] as? Int ?? 0, st["totalManga"] as? Int ?? 0)
            if state == "SUCCESS" { break }
            if state == "FAILURE" { throw FolioError("The backup couldn\u{2019}t be restored. It may be from an unsupported version.") }
        }
        return try await libraryFromEngine()
    }

    /// Imports a Tachimanga `.tmb` backup: converts its database, restores it through the engine, and keeps
    /// each series\u{2019} last-read time so Recent looks the way it did.
    public func importTachimangaBackup(_ file: Data, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [ImportedSeries] {
        let proto = try TachimangaBackup.tachiyomiBackup(from: file)
        let last = TachimangaBackup.lastRead(from: file)
        var items = try await importTachiyomiBackup(proto, name: "backup.proto.gz", progress: progress)
        for i in items.indices { if let d = last[items[i].key] { items[i].entry.lastRead = d } }
        return items
    }

    /// Everything the engine currently holds in its library (what a restore just put there).
    public func libraryFromEngine() async throws -> [ImportedSeries] {
        let d = try await q("""
            { mangas(condition:{inLibrary:true}) { nodes { id url title author artist description genre status thumbnailUrl realUrl sourceId
                categories { nodes { name } }
                chapters { nodes { id name chapterNumber uploadDate scanlator realUrl isRead isBookmarked lastPageRead } } } } }
            """)
        let nodes = ((d["mangas"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.map { m in
            let sid = "ext-" + String(describing: m["sourceId"] ?? "")
            let status = SeriesStatus(engine: m["status"] as? String)
            var s = Series(sourceID: sid, url: String(describing: m["id"] ?? ""), title: m["title"] as? String ?? "",
                           author: m["author"] as? String, artist: m["artist"] as? String, summary: m["description"] as? String,
                           genres: m["genre"] as? [String] ?? [], status: status, coverURL: m["thumbnailUrl"] as? String)
            s.webURL = (m["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let cs = ((m["chapters"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let states: [ChapterState] = cs.map { c in
                let up = (c["uploadDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                let num = (c["chapterNumber"] as? Double).flatMap { $0 >= 0 ? $0 : nil }
                var st = ChapterState(chapter: Chapter(url: String(describing: c["id"] ?? ""), name: c["name"] as? String ?? "", number: num,
                                                      uploaded: (up?.timeIntervalSince1970 ?? 0) > 0 ? up : nil, scanlator: c["scanlator"] as? String,
                                                      webURL: (c["realUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
                st.read = c["isRead"] as? Bool ?? false
                st.bookmarked = c["isBookmarked"] as? Bool ?? false
                st.lastPage = c["lastPageRead"] as? Int ?? 0
                return st
            }
            let cats = (((m["categories"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            return ImportedSeries(entry: LibraryEntry(series: s, chapters: states), categories: cats,
                                  key: "\(m["sourceId"] ?? "")|\(m["url"] ?? "")")
        }
    }
}

extension ExtensionEngine {
    public func repos() async throws -> [ExtensionRepo] {
        let d = try await q("{ extensionStores { nodes { name indexUrl } } }")
        let nodes = ((d["extensionStores"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.map { ExtensionRepo(name: $0["name"] as? String ?? "Repo", indexURL: $0["indexUrl"] as? String ?? "") }
    }

    /// Accepts any Tachiyomi/Mihon-style repo link: index.pb (current protobuf index), index.min.json, repo.json or the repo folder.
    public func addRepo(_ url: String) async throws -> ExtensionRepo {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: clean)?.scheme?.hasPrefix("http") == true else { throw FolioError("Paste the repo's https:// link") }
        let d = try await q("mutation($u: String!) { addExtensionStore(input:{indexUrl:$u}) { extensionStore { name indexUrl } } }", ["u": clean])
        let s = (d["addExtensionStore"] as? [String: Any])?["extensionStore"] as? [String: Any] ?? [:]
        return ExtensionRepo(name: s["name"] as? String ?? "Repo", indexURL: s["indexUrl"] as? String ?? clean)
    }

    public func removeRepo(_ indexURL: String) async throws {
        _ = try await q("mutation($u: String!) { removeExtensionStore(input:{indexUrl:$u}) { clientMutationId } }", ["u": indexURL])
    }

    static let extFields = "pkgName name lang versionName isInstalled hasUpdate isObsolete isNsfw iconUrl repo"

    static func ext(_ e: [String: Any]) -> ExtensionInfo {
        ExtensionInfo(pkgName: e["pkgName"] as? String ?? "", name: e["name"] as? String ?? "", lang: e["lang"] as? String ?? "",
                      version: e["versionName"] as? String ?? "", installed: e["isInstalled"] as? Bool ?? false,
                      hasUpdate: e["hasUpdate"] as? Bool ?? false, obsolete: e["isObsolete"] as? Bool ?? false,
                      nsfw: e["isNsfw"] as? Bool ?? false, iconPath: e["iconUrl"] as? String, repo: e["repo"] as? String)
    }

    /// Re-downloads every repo's index and returns all extensions.
    public func refreshExtensions() async throws -> [ExtensionInfo] {
        let d = try await q("mutation { fetchExtensions(input:{}) { extensions { \(Self.extFields) } } }")
        return (((d["fetchExtensions"] as? [String: Any])?["extensions"] as? [[String: Any]]) ?? []).map(Self.ext)
    }

    public func extensions() async throws -> [ExtensionInfo] {
        let d = try await q("{ extensions { nodes { \(Self.extFields) } } }")
        return (((d["extensions"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).map(Self.ext)
    }

    public enum ExtensionAction: String { case install, update, uninstall }

    public func perform(_ a: ExtensionAction, _ pkg: String) async throws {
        _ = try await q("mutation($id: String!) { updateExtension(input:{id:$id, patch:{\(a.rawValue):true}}) { extension { pkgName } } }", ["id": pkg])
    }

    public func sources() async throws -> [ExtensionSourceInfo] {
        let d = try await q("{ sources { nodes { id name lang displayName supportsLatest isNsfw iconUrl isConfigurable } } }")
        return (((d["sources"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).compactMap { s in
            guard let id = s["id"] as? String, id != "0" else { return nil }   // "0" = engine's own local source
            return ExtensionSourceInfo(id: id, name: s["name"] as? String ?? "", lang: s["lang"] as? String ?? "",
                                       displayName: s["displayName"] as? String ?? "", supportsLatest: s["supportsLatest"] as? Bool ?? false,
                                       nsfw: s["isNsfw"] as? Bool ?? false, iconPath: s["iconUrl"] as? String,
                                       isConfigurable: s["isConfigurable"] as? Bool)
        }
    }
}
