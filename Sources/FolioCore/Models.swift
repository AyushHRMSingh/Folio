import Foundation

// The three core models, following the Tachiyomi design: a source describes series, their
// chapters, and the pages of a chapter. `url` is the source-specific stable key for each.

public enum SeriesStatus: String, Codable, Sendable { case unknown, ongoing, completed }

public struct Series: Codable, Hashable, Sendable, Identifiable {
    public var sourceID: String
    public var url: String
    public var title: String
    public var author: String?
    public var artist: String?
    public var summary: String?
    public var genres: [String]
    public var status: SeriesStatus
    public var coverURL: String?
    /// The series' page on the source's website, when the source knows it.
    public var webURL: String?
    public var id: String { sourceID + "|" + url }

    public init(sourceID: String, url: String, title: String, author: String? = nil, artist: String? = nil,
                summary: String? = nil, genres: [String] = [], status: SeriesStatus = .unknown, coverURL: String? = nil) {
        self.sourceID = sourceID; self.url = url; self.title = title; self.author = author; self.artist = artist
        self.summary = summary; self.genres = genres; self.status = status; self.coverURL = coverURL
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)     // identity
        url = try c.decode(String.self, forKey: .url)
        title = c.lenient(String.self, .title) ?? url
        author = c.lenient(String.self, .author)
        artist = c.lenient(String.self, .artist)
        summary = c.lenient(String.self, .summary)
        genres = c.lenient([String].self, .genres) ?? []
        status = c.lenient(SeriesStatus.self, .status) ?? .unknown
        coverURL = c.lenient(String.self, .coverURL)
        webURL = c.lenient(String.self, .webURL)
    }
}

public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public var url: String
    public var name: String
    /// Parsed chapter number; -1 when unknown.
    public var number: Double
    public var uploaded: Date?
    public var scanlator: String?
    /// The chapter's page on the source's website, when the source knows it.
    public var webURL: String?
    public var id: String { url }

    public init(url: String, name: String, number: Double? = nil, uploaded: Date? = nil, scanlator: String? = nil, webURL: String? = nil) {
        self.webURL = webURL
        self.url = url; self.name = name
        self.number = number ?? ChapterRecognition.number(from: name)
        self.uploaded = uploaded; self.scanlator = scanlator
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)               // identity
        name = c.lenient(String.self, .name) ?? url
        number = c.lenient(Double.self, .number) ?? ChapterRecognition.number(from: name)
        uploaded = c.lenient(Date.self, .uploaded)
        scanlator = c.lenient(String.self, .scanlator)
        webURL = c.lenient(String.self, .webURL)
    }
}

/// One page image. Remote pages may need the source's credentials to fetch.
public enum PageRef: Hashable, Sendable {
    case file(URL)
    case remote(URL)
}

/// A page of results from a catalogue listing or search.
public struct SeriesPage: Sendable {
    public var series: [Series]
    public var hasNextPage: Bool
    public init(series: [Series], hasNextPage: Bool) { self.series = series; self.hasNextPage = hasNextPage }
}

public struct FolioError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ d: String) { description = d }
    public var errorDescription: String? { description }
}
