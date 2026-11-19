import Foundation

struct BackupFile: Codable {
    static let formatName = "folio-backup"
    var format = BackupFile.formatName
    var version = 1
    var created: Date
    var library: LibraryFile
    var covers: [String: Data] = [:]
}

extension Library {
    // MARK: backup

    /// Your library, reading progress, categories, settings and picked covers as one file.
    public func backupData() throws -> Data {
        var covers: [String: Data] = [:]
        for e in entries { if let c = e.customCover, let d = try? Data(contentsOf: URL(fileURLWithPath: c)) { covers[(c as NSString).lastPathComponent] = d } }
        var safe = settings   // backups never carry OPDS passwords
        for i in safe.servers.indices { safe.servers[i].password = "" }
        let b = BackupFile(created: Date(), library: LibraryFile(entries: entries, settings: safe), covers: covers)
        return try JSONEncoder.folio.encode(b)
    }

    /// Replaces the library with a backup. Returns how many series came back. Downloads aren't in backups,
    /// so restored chapters are marked not-downloaded.
    @discardableResult
    public func restore(_ data: Data) throws -> Int {
        guard let b = try? JSONDecoder.folio.decode(BackupFile.self, from: data), b.format == BackupFile.formatName else {
            throw FolioError("That isn\u{2019}t a Folio backup.")
        }
        var lib = b.library
        for (name, d) in b.covers { try? d.write(to: Paths.covers.appendingPathComponent(name)) }
        for i in lib.entries.indices {
            if let c = lib.entries[i].customCover {
                let path = Paths.covers.appendingPathComponent((c as NSString).lastPathComponent).path
                lib.entries[i].customCover = path; lib.entries[i].series.coverURL = path
            }
            for k in lib.entries[i].chapters.indices where lib.entries[i].chapters[k].downloaded {
                let dir = downloadDir(seriesID: lib.entries[i].series.id, chapter: lib.entries[i].chapters[k].chapter.url)
                if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".complete").path) { lib.entries[i].chapters[k].downloaded = false }
            }
        }
        for i in lib.settings.servers.indices where lib.settings.servers[i].password.isEmpty {
            if let old = settings.servers.first(where: { $0.id == lib.settings.servers[i].id }) { lib.settings.servers[i].password = old.password }
        }
        entries = lib.entries
        settings = lib.settings
        save()
        return entries.count
    }

    /// Adds series read from a Tachiyomi-family backup. Series already in the library are left alone.
    /// Categories are matched by name and created when missing.
    @discardableResult
    public func importSeries(_ items: [ImportedSeries]) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for item in items {
            if entry(item.entry.id) != nil { skipped += 1; continue }
            var e = item.entry
            e.saved = true
            e.added = Date()
            var ids: [String] = []
            for name in item.categories where !name.isEmpty {
                if let c = settings.categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { ids.append(c.id) }
                else { let c = LibraryCategory(name: name); settings.categories.append(c); ids.append(c.id) }
            }
            if !ids.isEmpty { e.categoryIDs = ids }
            entries.append(e)
            added += 1
        }
        if added > 0 { scheduleSave() }
        return (added, skipped)
    }

    /// Saves a dated backup into Folio's Backups folder and prunes old ones. Returns its URL.
    @discardableResult
    public func writeAutoBackup(keep: Int = 5) -> URL? {
        guard let d = try? backupData() else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = Paths.backups.appendingPathComponent("folio-\(f.string(from: Date())).foliobackup")
        guard (try? d.write(to: url)) != nil else { return nil }
        let all = ((try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "foliobackup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in all.dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: old) }
        return url
    }

    /// Newest automatic backup, if any.
    public var latestAutoBackup: (url: URL, date: Date)? {
        let all = ((try? FileManager.default.contentsOfDirectory(at: Paths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "foliobackup" }
        return all.compactMap { u in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (u, $0) } }
            .max { $0.1 < $1.1 }
    }
}
