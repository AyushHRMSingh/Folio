import Foundation

/// Reads series from a folder you control (default: Folio's own "Local" folder).
///   <root>/<Series>/                  one series
///   <root>/<Series>/cover.jpg         optional cover
///   <root>/<Series>/<Chapter>/*.jpg   a chapter as a folder of images
///   <root>/<Series>/<Chapter>.cbz     a chapter as an archive (.cbz / .zip)
///   <root>/<Series>/*.jpg             loose images = a single chapter
///   <root>/<Series>/details.json      optional {title, author, artist, description, genre[], status}
public final class LocalSource: Source, @unchecked Sendable {
    public let id = "local"
    public let name = "Local files"
    public let root: URL
    private let pageSize = 60

    public init(root: URL = Paths.localLibrary) { self.root = root }

    private var fm: FileManager { .default }

    private func seriesDirs() -> [URL] {
        ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                      options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func series(for dir: URL) -> Series {
        var s = Series(sourceID: id, url: dir.lastPathComponent, title: dir.lastPathComponent)
        s.coverURL = cover(in: dir)?.path
        if let d = try? Data(contentsOf: dir.appendingPathComponent("details.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let t = j["title"] as? String, !t.isEmpty { s.title = t }
            s.author = j["author"] as? String
            s.artist = j["artist"] as? String
            s.summary = j["description"] as? String
            s.genres = (j["genre"] as? [String]) ?? []
            let st = j["status"] as? String ?? ""
            s.status = SeriesStatus(rawValue: st.lowercased()) ?? SeriesStatus(engine: st)
        }
        return s
    }

    private func cover(in dir: URL) -> URL? {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.deletingPathExtension().lastPathComponent.lowercased() == "cover" && Paths.isImage($0) }
    }

    private func page(_ list: [URL], _ page: Int) -> SeriesPage {
        let start = max(0, (page - 1) * pageSize)
        let slice = list.dropFirst(start).prefix(pageSize)
        return SeriesPage(series: slice.map(series(for:)), hasNextPage: start + pageSize < list.count)
    }

    public func popular(page: Int) async throws -> SeriesPage {
        let dirs = seriesDirs().sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return self.page(dirs, page)
    }

    public func search(_ query: String, page: Int) async throws -> SeriesPage {
        let q = query.trimmingCharacters(in: .whitespaces)
        let dirs = seriesDirs().filter { q.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(q) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return self.page(dirs, page)
    }

    public func details(_ s: Series) async throws -> Series {
        let dir = root.appendingPathComponent(s.url, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { throw FolioError("\(s.title) is no longer in the local folder") }
        var out = series(for: dir)
        if out.coverURL == nil, let first = try await chapters(s).readingOrder().first,
           let firstPage = try await pages(first, of: s).first, case .file(let u) = firstPage {
            out.coverURL = u.path
        }
        return out
    }

    public func chapters(_ s: Series) async throws -> [Chapter] {
        let dir = root.appendingPathComponent(s.url, isDirectory: true)
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var chapters: [Chapter] = []
        var looseImages = false
        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let date = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if isDir, !Archive.images(in: u).isEmpty {
                chapters.append(Chapter(url: u.lastPathComponent, name: u.lastPathComponent, uploaded: date))
            } else if Paths.isArchive(u) {
                chapters.append(Chapter(url: u.lastPathComponent, name: u.deletingPathExtension().lastPathComponent, uploaded: date))
            } else if Paths.isImage(u), u.deletingPathExtension().lastPathComponent.lowercased() != "cover" {
                looseImages = true
            }
        }
        if looseImages { chapters.append(Chapter(url: ".", name: s.title, number: 1)) }
        return chapters
    }

    public func pages(_ c: Chapter, of s: Series) async throws -> [PageRef] {
        let base = root.appendingPathComponent(s.url, isDirectory: true)
        if c.url == "." {
            return ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { Paths.isImage($0) && $0.deletingPathExtension().lastPathComponent.lowercased() != "cover" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { .file($0) }
        }
        let u = base.appendingPathComponent(c.url)
        let dir = Paths.isArchive(u) ? try Archive.extracted(u) : u
        let imgs = Archive.images(in: dir)
        guard !imgs.isEmpty else { throw FolioError("No images found in \(c.name)") }
        return imgs.map { .file($0) }
    }

    public func coverData(_ s: Series) async throws -> Data? {
        guard let p = s.coverURL else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: p))
    }

    /// Copies a folder or archive into the local library (into Folio's data folder).
    /// An archive becomes a single-chapter series; a folder keeps its structure.
    public func importItem(_ src: URL) throws -> String {
        let name = src.deletingPathExtension().lastPathComponent
        // Importing the same folder or file twice must not create "Name 2": remember where each copy came from.
        let marker = ".folio-origin"
        if let kids = try? fm.contentsOfDirectory(atPath: root.path) {
            for k in kids {
                let m = root.appendingPathComponent(k).appendingPathComponent(marker)
                if let o = try? String(contentsOf: m, encoding: .utf8), o == src.path { return k }
            }
        }
        var dest = root.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = root.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1 }
        let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir {
            try fm.copyItem(at: src, to: dest)
        } else if Paths.isArchive(src) {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent))
        } else {
            throw FolioError("\(src.lastPathComponent): import a folder or a .cbz/.zip file")
        }
        try? src.path.write(to: dest.appendingPathComponent(marker), atomically: true, encoding: .utf8)
        return dest.lastPathComponent
    }
}
