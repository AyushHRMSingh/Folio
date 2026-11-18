import Foundation
import SQLite3

/// Reads a Tachimanga backup (`.tmb`) and turns it into a Tachiyomi-format backup the engine can restore.
///
/// A `.tmb` is a zip holding `meta.json` and `contents.zip`; inside that is `tachimanga.db`, a SQLite
/// database shaped like the engine's own (Manga, Chapter, Category, History…).
public enum TachimangaBackup {
    public static func looksLike(_ data: Data, name: String) -> Bool {
        name.lowercased().hasSuffix(".tmb") || data.starts(with: [0x50, 0x4b, 0x03, 0x04])      // a zip, not a gzip
    }

    /// Returns a gzip'd Tachiyomi protobuf backup holding the library in `data`.
    public static func tachiyomiBackup(from data: Data) throws -> Data {
        let work = Paths.cache.appendingPathComponent("tmb-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let outer = work.appendingPathComponent("backup.tmb")
        try data.write(to: outer)
        try run("/usr/bin/unzip", ["-o", "-q", outer.path, "-d", work.appendingPathComponent("outer").path])
        let inner = work.appendingPathComponent("outer/contents.zip")
        guard FileManager.default.fileExists(atPath: inner.path) else { throw FolioError("That doesn\u{2019}t look like a Tachimanga backup.") }
        try run("/usr/bin/unzip", ["-o", "-q", inner.path, "tachimanga.db", "-d", work.appendingPathComponent("inner").path])
        let db = work.appendingPathComponent("inner/tachimanga.db")
        guard FileManager.default.fileExists(atPath: db.path) else { throw FolioError("This backup has no library database.") }
        let proto = try library(fromDatabase: db)
        return try gzip(proto)
    }

    /// Last-read times by "sourceID|mangaURL", so imported series keep their place in Recent.
    public static func lastRead(from data: Data) -> [String: Date] {
        let work = Paths.cache.appendingPathComponent("tmb-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: work.appendingPathComponent("b.tmb"))) != nil,
              (try? run("/usr/bin/unzip", ["-o", "-q", work.appendingPathComponent("b.tmb").path, "-d", work.appendingPathComponent("o").path])) != nil,
              (try? run("/usr/bin/unzip", ["-o", "-q", work.appendingPathComponent("o/contents.zip").path, "tachimanga.db", "-d", work.appendingPathComponent("i").path])) != nil,
              let db = try? SQLiteDB(work.appendingPathComponent("i/tachimanga.db")) else { return [:] }
        var out: [String: Date] = [:]
        db.rows("select m.source, m.url, h.last_read_at from History h join Manga m on m.id = h.manga_id where h.is_delete = 0") { r in
            let t = r.double(2)
            if t > 0 { out["\(r.int(0))|\(r.text(1))"] = Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t) }
        }
        return out
    }

    // MARK: database → protobuf

    static func library(fromDatabase url: URL) throws -> Data {
        let db = try SQLiteDB(url)
        var backup = ProtoWriter()

        // Categories: Tachiyomi refers to them by their order number.
        var categoryOrder: [Int64: Int64] = [:]
        db.rows("select id, name, \"order\" from Category where is_delete = 0 and is_default = 0") { r in
            categoryOrder[r.int(0)] = r.int(2)
            var c = ProtoWriter(); c.string(1, r.text(1)); c.varint(2, UInt64(max(0, r.int(2))))
            backup.bytes(2, c.data)
        }
        var mangaCategories: [Int64: [Int64]] = [:]
        db.rows("select manga, category from CategoryManga") { r in
            if let o = categoryOrder[r.int(1)] { mangaCategories[r.int(0), default: []].append(o) }
        }
        var history: [Int64: (chapter: String, at: Int64, duration: Int64)] = [:]
        db.rows("select h.manga_id, c.url, h.last_read_at, h.read_duration from History h join Chapter c on c.id = h.last_chapter_id where h.is_delete = 0") { r in
            history[r.int(0)] = (r.text(1), r.int(2), r.int(3))
        }
        func ms(_ t: Int64) -> UInt64 { UInt64(max(0, t > 100_000_000_000 ? t : t * 1000)) }

        var count = 0
        var mangaRows: [(id: Int64, w: ProtoWriter)] = []
        db.rows("select id, source, url, title, artist, author, description, genre, status, thumbnail_url, in_library_at from Manga where in_library = 1") { r in
            var m = ProtoWriter()
            m.varint(1, UInt64(bitPattern: r.int(1)))
            m.string(2, r.text(2)); m.string(3, r.text(3))
            if let a = r.optText(4) { m.string(4, a) }
            if let a = r.optText(5) { m.string(5, a) }
            if let d = r.optText(6) { m.string(6, d) }
            for g in (r.optText(7) ?? "").components(separatedBy: ",") {
                let t = g.trimmingCharacters(in: .whitespaces); if !t.isEmpty { m.string(7, t) }
            }
            m.varint(8, UInt64(max(0, r.int(8))))
            if let t = r.optText(9) { m.string(9, t) }
            m.varint(13, ms(r.int(10)))
            for o in mangaCategories[r.int(0)] ?? [] { m.varint(17, UInt64(max(0, o))) }
            m.varint(100, 1)                                       // favourite
            mangaRows.append((r.int(0), m))
        }
        for var row in mangaRows {
            db.rows("select url, name, scanlator, \"read\", bookmark, last_page_read, fetched_at, date_upload, chapter_number, source_order from Chapter where manga = \(row.id)") { r in
                var c = ProtoWriter()
                c.string(1, r.text(0)); c.string(2, r.text(1))
                if let s = r.optText(2) { c.string(3, s) }
                c.varint(4, r.int(3) != 0 ? 1 : 0); c.varint(5, r.int(4) != 0 ? 1 : 0)
                c.varint(6, UInt64(max(0, r.int(5))))
                c.varint(7, ms(r.int(6))); c.varint(8, ms(r.int(7)))
                c.float(9, Float(r.double(8)))
                c.varint(10, UInt64(max(0, r.int(9))))
                row.w.bytes(16, c.data)
            }
            if let h = history[row.id] {
                var hw = ProtoWriter(); hw.string(1, h.chapter); hw.varint(2, ms(h.at)); hw.varint(3, UInt64(max(0, h.duration)))
                row.w.bytes(104, hw.data)
            }
            backup.bytes(1, row.w.data)
            count += 1
        }
        guard count > 0 else { throw FolioError("This backup has no series in its library.") }
        return backup.data
    }

    // MARK: helpers

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FolioError("Couldn\u{2019}t open the backup file.") }
    }

    static func gzip(_ d: Data) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); p.arguments = ["-c"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        DispatchQueue.global().async { inp.fileHandleForWriting.write(d); try? inp.fileHandleForWriting.close() }
        let result = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FolioError("Couldn\u{2019}t prepare the backup.") }
        return result
    }
}

/// Minimal protobuf encoder (only what the Tachiyomi backup schema needs).
struct ProtoWriter {
    var data = Data()
    private mutating func put(_ v: UInt64) {
        var v = v
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; data.append(b) } while v != 0
    }
    mutating func varint(_ n: Int, _ v: UInt64) { put(UInt64(n << 3)); put(v) }
    mutating func bytes(_ n: Int, _ d: Data) { put(UInt64(n << 3 | 2)); put(UInt64(d.count)); data.append(d) }
    mutating func string(_ n: Int, _ s: String) { bytes(n, Data(s.utf8)) }
    mutating func float(_ n: Int, _ f: Float) {
        put(UInt64(n << 3 | 5))
        var bits = f.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}

/// Tiny read-only SQLite wrapper.
final class SQLiteDB {
    struct Row {
        let s: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
        func optText(_ i: Int32) -> String? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_text(s, i).map { String(cString: $0) } }
        func text(_ i: Int32) -> String { optText(i) ?? "" }
    }
    private var db: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw FolioError("Couldn\u{2019}t read the backup\u{2019}s database.") }
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ each: (Row) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { each(Row(s: st)) }
    }
}
