import Foundation

/// A provider of series. Folio itself contains no content: everything comes from sources.
public protocol Source: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }

    /// Browse listing, paged (page starts at 1).
    func popular(page: Int) async throws -> SeriesPage
    func search(_ query: String, page: Int) async throws -> SeriesPage
    /// The source's own filter controls (genres, status, sort…). Empty when it has none.
    func filters() async throws -> [SourceFilter]
    /// Per-source settings (content rating, image quality…). Empty when it has none.
    func preferences() async throws -> [SourcePreference]
    /// Saves one setting and returns the source's updated list.
    func setPreference(_ p: SourcePreference) async throws -> [SourcePreference]
    /// Search with filters applied; `query` may be empty to browse by filters alone.
    func search(_ query: String, filters: [SourceFilter], page: Int) async throws -> SeriesPage

    /// Refresh metadata for a series.
    func details(_ series: Series) async throws -> Series
    /// All chapters, any order (the library sorts them).
    func chapters(_ series: Series) async throws -> [Chapter]
    /// Page images of a chapter, in reading order.
    func pages(_ chapter: Chapter, of series: Series) async throws -> [PageRef]

    /// Loads image bytes for a page (applies credentials for remote sources).
    func imageData(_ page: PageRef) async throws -> Data
    /// Loads cover bytes, if any.
    func coverData(_ series: Series) async throws -> Data?
}

public extension Source {
    func filters() async throws -> [SourceFilter] { [] }
    func preferences() async throws -> [SourcePreference] { [] }
    func setPreference(_ p: SourcePreference) async throws -> [SourcePreference] { [] }
    func search(_ query: String, filters: [SourceFilter], page: Int) async throws -> SeriesPage { try await search(query, page: page) }

    func imageData(_ page: PageRef) async throws -> Data {
        switch page {
        case .file(let u): return try Data(contentsOf: u)
        case .remote(let u):
            return try await ImageFetch.data(key: u.absoluteString, group: u.host) {
                let (d, h) = try await Net.data(for: URLRequest(url: u))
                guard (200..<300).contains(h.statusCode) else { throw FolioError("Couldn't load image (HTTP \(h.statusCode))") }
                return d
            }
        }
    }
}

/// Parses a chapter number out of a name such as "Vol.2 Ch. 12.5 - Title" or "chapter_007.cbz".
public enum ChapterRecognition {
    public static func number(from name: String) -> Double {
        let lower = name.lowercased()
            .replacingOccurrences(of: #"\.(cbz|zip|cbr|rar|epub|pdf)$"#, with: "", options: .regularExpression)
        let patterns = [
            #"(?:ch(?:apter)?|chap|episode|ep|#)\.?\s*(\d+(?:\.\d+)?)"#,   // explicit marker wins
            #"(?:^|[^\d.])(\d+(?:\.\d+)?)\s*$"#,                             // trailing number
            #"(\d+(?:\.\d+)?)"#,                                             // first number at all
        ]
        // Volume numbers shouldn't be mistaken for chapters.
        let withoutVolume = lower.replacingOccurrences(of: #"\b(?:vol(?:ume)?|v)\.?\s*\d+"#, with: " ", options: .regularExpression)
        for (i, p) in patterns.enumerated() {
            let hay = i == 0 ? lower : withoutVolume
            if let r = hay.range(of: p, options: .regularExpression),
               let m = try? NSRegularExpression(pattern: p).firstMatch(in: hay, range: NSRange(r, in: hay)),
               let g = Range(m.range(at: 1), in: hay), let n = Double(hay[g]) {
                return n
            }
        }
        return -1
    }
}

public extension Array where Element == Chapter {
    /// Reading order: by number, then by name.
    func readingOrder() -> [Chapter] {
        sorted {
            if $0.number != $1.number { return ($0.number < 0 ? .infinity : $0.number) < ($1.number < 0 ? .infinity : $1.number) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
