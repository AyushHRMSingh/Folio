import Foundation

// MARK: - Atom/OPDS feed model + parser

public struct OPDSLink: Sendable, Hashable {
    public var rel: String
    public var type: String
    public var href: URL
    public var pseCount: Int?
}

public struct OPDSEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var author: String?
    public var summary: String?
    public var updated: Date?
    public var links: [OPDSLink]

    public var acquisition: URL? { links.first { $0.rel.hasPrefix("http://opds-spec.org/acquisition") }?.href }
    public var stream: OPDSLink? { links.first { $0.rel == "http://vaemendis.net/opds-pse/stream" } }
    public var cover: URL? {
        links.first { $0.rel == "http://opds-spec.org/image" }?.href
            ?? links.first { $0.rel == "http://opds-spec.org/image/thumbnail" || $0.rel == "x-stanza-cover-image" }?.href
    }
    public var thumbnail: URL? { links.first { $0.rel == "http://opds-spec.org/image/thumbnail" }?.href ?? cover }
    /// A link to another feed (a series, a library, a section).
    public var navigation: URL? {
        links.first { $0.type.contains("application/atom+xml") && !$0.rel.hasPrefix("http://opds-spec.org/") && $0.rel != "self" }?.href
    }
    /// Readable item (a chapter/volume/book).
    public var isBook: Bool { acquisition != nil || stream != nil }
}

public struct OPDSFeed: Sendable {
    public var title: String
    public var entries: [OPDSEntry]
    public var next: URL?
    public var search: OPDSLink?
}

final class OPDSParser: NSObject, XMLParserDelegate {
    private let base: URL
    private var feed = OPDSFeed(title: "", entries: [], next: nil, search: nil)
    private var entry: OPDSEntry?
    private var text = ""
    private var inAuthor = false

    init(base: URL) { self.base = base }

    static func parse(_ data: Data, base: URL) throws -> OPDSFeed {
        let p = OPDSParser(base: base)
        let x = XMLParser(data: data)
        x.shouldProcessNamespaces = false
        x.delegate = p
        guard x.parse() else { throw FolioError("Not a valid OPDS feed (\(x.parserError?.localizedDescription ?? "parse error"))") }
        return p.feed
    }

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        text = ""
        let local = name.split(separator: ":").last.map(String.init) ?? name
        switch local {
        case "entry": entry = OPDSEntry(id: "", title: "", links: [])
        case "author": inAuthor = true
        case "link":
            guard let h = a["href"], let url = URL(string: h, relativeTo: base)?.absoluteURL else { return }
            let count = a.first { $0.key.hasSuffix(":count") || $0.key == "count" }.flatMap { Int($0.value) }
            let link = OPDSLink(rel: a["rel"] ?? "", type: a["type"] ?? "", href: url, pseCount: count)
            if entry != nil { entry!.links.append(link) }
            else if link.rel == "next" { feed.next = url }
            else if link.rel == "search" { feed.search = link }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "entry":
            if let e = entry { feed.entries.append(e) }
            entry = nil
        case "title": if entry != nil { entry!.title = t } else if feed.title.isEmpty { feed.title = t }
        case "id": if entry != nil { entry!.id = t }
        case "name": if inAuthor, entry != nil, entry!.author == nil { entry!.author = t }
        case "author": inAuthor = false
        case "summary", "content": if entry != nil, !t.isEmpty, entry!.summary == nil { entry!.summary = t }
        case "updated": if entry != nil { entry!.updated = Self.iso.date(from: t) ?? Self.isoFrac.date(from: t) }
        default: break
        }
        text = ""
    }
}

// MARK: - Source

public struct OPDSServer: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    public var username: String
    public var password: String
    public init(id: String = UUID().uuidString, name: String, url: String, username: String = "", password: String = "") {
        self.id = id; self.name = name; self.url = url; self.username = username; self.password = password
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id) ?? UUID().uuidString
        name = c.lenient(String.self, .name) ?? "Server"
        url = try c.decode(String.self, forKey: .url)
        username = c.lenient(String.self, .username) ?? ""
        password = c.lenient(String.self, .password) ?? ""
    }
}

/// Self-hosted catalog (Komga, Kavita, Calibre-web, …) over OPDS 1.x with Page Streaming (PSE).
/// A "series" is a feed; its book entries are chapters. Pages stream one by one via PSE when the
/// server supports it, otherwise the chapter archive is downloaded and opened locally.
public final class OPDSSource: Source, @unchecked Sendable {
    public let server: OPDSServer
    public var id: String { "opds-" + server.id }
    public var name: String { server.name }
    private let lock = NSLock()
    private var pageURLs: [Int: URL] = [:]

    public init(_ server: OPDSServer) { self.server = server }

    private var auth: String? {
        guard !server.username.isEmpty else { return nil }
        return "Basic " + Data("\(server.username):\(server.password)".utf8).base64EncodedString()
    }

    func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url)
        if let auth { r.setValue(auth, forHTTPHeaderField: "Authorization") }
        r.setValue("application/atom+xml, image/*, */*", forHTTPHeaderField: "Accept")
        let (d, h) = try await Net.data(for: r)
        if !(200..<300).contains(h.statusCode) {
            throw FolioError(h.statusCode == 401 ? "\(server.name): wrong username or password" : "\(server.name): HTTP \(h.statusCode)")
        }
        return d
    }

    public func feed(_ url: URL) async throws -> OPDSFeed { try OPDSParser.parse(try await get(url), base: url) }

    public var rootURL: URL {
        get throws {
            guard let u = URL(string: server.url), u.scheme != nil else { throw FolioError("Invalid server URL: \(server.url)") }
            return u
        }
    }

    func series(from e: OPDSEntry, feedURL: URL) -> Series {
        Series(sourceID: id, url: (e.navigation ?? feedURL).absoluteString, title: e.title, author: e.author,
               summary: e.summary, coverURL: e.thumbnail?.absoluteString)
    }

    private func list(_ url: URL, page: Int) async throws -> SeriesPage {
        let f = try await feed(url)
        let items = f.entries.filter { $0.navigation != nil && !$0.isBook }.map { series(from: $0, feedURL: url) }
        if let n = f.next { lock.withLock { pageURLs[page + 1] = n } }
        return SeriesPage(series: items, hasNextPage: f.next != nil)
    }

    public func popular(page: Int) async throws -> SeriesPage {
        let next: URL? = page == 1 ? try rootURL : lock.withLock { pageURLs[page] }
        guard let url = next else { return SeriesPage(series: [], hasNextPage: false) }
        return try await list(url, page: page)
    }

    public func search(_ query: String, page: Int) async throws -> SeriesPage {
        guard page == 1 else { return try await popular(page: page) }
        let root = try await feed(try rootURL)
        guard let link = root.search else { throw FolioError("\(server.name) doesn't support search") }
        var template = link.href.absoluteString.removingPercentEncoding ?? link.href.absoluteString
        if link.type.contains("opensearchdescription") {
            let d = try await get(link.href)
            let xml = String(decoding: d, as: UTF8.self)
            guard let r = xml.range(of: #"template="([^"]+)""#, options: .regularExpression) else {
                throw FolioError("\(server.name): unreadable search description")
            }
            template = String(xml[r]).replacingOccurrences(of: "template=\"", with: "").dropLast().description
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: template.replacingOccurrences(of: "{searchTerms}", with: q), relativeTo: link.href)?.absoluteURL
        else { throw FolioError("bad search URL") }
        let f = try await feed(url)
        var out = f.entries.filter { $0.navigation != nil && !$0.isBook }.map { series(from: $0, feedURL: url) }
        // Some servers return books directly; group them under their feed.
        if out.isEmpty, f.entries.contains(where: \.isBook) {
            out = [Series(sourceID: id, url: url.absoluteString, title: "Results for “\(query)”")]
        }
        return SeriesPage(series: out, hasNextPage: false)
    }

    public func details(_ s: Series) async throws -> Series { s }

    /// Chapter.url encodes how to read it: the PSE template + page count and/or the download link.
    struct Ref: Codable { var stream: String?; var count: Int?; var download: String? }

    public func chapters(_ s: Series) async throws -> [Chapter] {
        guard var url = URL(string: s.url) else { return [] }
        var books: [OPDSEntry] = []
        var subfeeds: [URL] = []
        var seen = Set<URL>()
        while !seen.contains(url) {          // follow paging
            seen.insert(url)
            let f = try await feed(url)
            books += f.entries.filter(\.isBook)
            subfeeds += f.entries.filter { !$0.isBook }.compactMap(\.navigation)
            guard let n = f.next else { break }
            url = n
        }
        if books.isEmpty {                    // e.g. series → volumes → books: go one level deeper
            for sub in subfeeds.prefix(50) { books += try await feed(sub).entries.filter(\.isBook) }
        }
        return books.map { e in
            let ref = Ref(stream: e.stream?.href.absoluteString.removingPercentEncoding, count: e.stream?.pseCount,
                          download: e.acquisition?.absoluteString)
            let key = "opds:" + ((try? JSONEncoder().encode(ref).base64EncodedString()) ?? e.id)
            return Chapter(url: key, name: e.title, uploaded: e.updated, scanlator: e.author)
        }
    }

    public func pages(_ c: Chapter, of s: Series) async throws -> [PageRef] {
        guard c.url.hasPrefix("opds:"), let d = Data(base64Encoded: String(c.url.dropFirst(5))),
              let ref = try? JSONDecoder().decode(Ref.self, from: d) else { throw FolioError("Unreadable chapter reference") }
        if let t = ref.stream, let n = ref.count, n > 0 {
            return (0..<n).compactMap { i in
                URL(string: t.replacingOccurrences(of: "{pageNumber}", with: String(i))
                    .replacingOccurrences(of: "{maxWidth}", with: "2400")).map { .remote($0) }
            }
        }
        guard let dl = ref.download, let u = URL(string: dl) else { throw FolioError("\(c.name) has no readable link") }
        // No streaming: fetch the archive once into Folio's cache and read it locally.
        let file = Paths.cache.appendingPathComponent("opds-" + Paths.hash(dl) + ".cbz")
        if !FileManager.default.fileExists(atPath: file.path) {
            try await get(u).write(to: file, options: .atomic)
        }
        return Archive.images(in: try Archive.extracted(file)).map { .file($0) }
    }

    public func imageData(_ page: PageRef) async throws -> Data {
        switch page {
        case .file(let u): return try Data(contentsOf: u)
        case .remote(let u): return try await ImageFetch.data(key: "o|\(server.id)|" + u.absoluteString, group: id) { try await get(u) }
        }
    }

    public func coverData(_ s: Series) async throws -> Data? {
        guard let c = s.coverURL, let u = URL(string: c) else { return nil }
        return try? await ImageFetch.data(key: "o|\(server.id)|" + c, group: id, maxAge: 7 * 86400) { try await get(u) }
    }
}
