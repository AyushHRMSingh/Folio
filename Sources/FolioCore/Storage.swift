import CryptoKit
import Foundation

/// Every byte Folio writes lives under $HOME/Library/Application Support/Folio, so the whole
/// app is self-contained and easy to back up, move or delete. Folio never uses UserDefaults,
/// window restoration or URLCache, which would write elsewhere through system daemons.
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    }
    public static var root: URL { dir(home.appendingPathComponent("Library/Application Support/Folio", isDirectory: true)) }
    public static var localLibrary: URL { dir(root.appendingPathComponent("Local", isDirectory: true)) }
    public static var backups: URL { dir(root.appendingPathComponent("Backups", isDirectory: true)) }
    public static var covers: URL { dir(root.appendingPathComponent("Covers", isDirectory: true)) }
    public static var downloads: URL { dir(root.appendingPathComponent("Downloads", isDirectory: true)) }
    public static var cache: URL { dir(root.appendingPathComponent("Cache", isDirectory: true)) }
    public static var libraryFile: URL { root.appendingPathComponent("library.json") }

    @discardableResult
    static func dir(_ u: URL) -> URL {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    public static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "bmp", "jxl"]
    static func isImage(_ u: URL) -> Bool { imageExtensions.contains(u.pathExtension.lowercased()) && !u.lastPathComponent.hasPrefix(".") }
    static let archiveExtensions: Set<String> = ["cbz", "zip"]
    static func isArchive(_ u: URL) -> Bool { archiveExtensions.contains(u.pathExtension.lowercased()) }
}

/// CBZ/ZIP support via the system `unzip` tool. Extracted chapters are cached under Folio's
/// data folder, keyed by archive path + modification date.
enum Archive {
    static func extracted(_ archive: URL) throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: archive.path)
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let dest = Paths.cache.appendingPathComponent("x-" + Paths.hash("\(archive.path)|\(stamp)"), isDirectory: true)
        let done = dest.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: done.path) { return dest }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", "-o", archive.path, "-d", dest.path]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 1 else {   // 1 = warnings only
            throw FolioError("Couldn't open \(archive.lastPathComponent): \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        FileManager.default.createFile(atPath: done.path, contents: nil)
        return dest
    }

    /// All images in a folder tree, in natural reading order.
    static func images(in dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let all = en.compactMap { $0 as? URL }.filter { Paths.isImage($0) && !$0.path.contains("__MACOSX") }
        return all.sorted {
            $0.path.replacingOccurrences(of: dir.path, with: "")
                .localizedStandardCompare($1.path.replacingOccurrences(of: dir.path, with: "")) == .orderedAscending
        }
    }
}
