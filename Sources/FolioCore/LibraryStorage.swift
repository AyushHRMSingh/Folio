import Foundation

extension Library {
    // MARK: storage

    public struct StorageUsage: Sendable {
        public var downloads: Int64
        public var cache: Int64
        public init(downloads: Int64, cache: Int64) { self.downloads = downloads; self.cache = cache }
    }

    public func storageUsage() -> StorageUsage {
        StorageUsage(downloads: Self.size(of: Paths.downloads), cache: Self.size(of: Paths.cache) + ExtensionEngine.cacheSize())
    }

    public nonisolated static func size(of dir: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    public func clearCache() {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: Paths.cache, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: u) }
        ExtensionEngine.clearEngineCaches(includingNetwork: ExtensionEngine.shared.state != .running)
        DiskCache.shared.clear()
    }

    public func clearAllDownloads() {
        cancelDownloads()
        for e in entries { try? FileManager.default.removeItem(at: downloadDir(seriesID: e.id)) }
        for i in entries.indices { for j in entries[i].chapters.indices { entries[i].chapters[j].downloaded = false } }
        scheduleSave()
    }
}
