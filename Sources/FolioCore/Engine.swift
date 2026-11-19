import CryptoKit
import Foundation

/// Runs real Tachiyomi/Mihon Android extensions (e.g. from Keiyoushi) the same way Tachimanga does:
/// through the open-source Suwayomi engine, which converts each extension APK to Java and loads it.
///
/// The engine runs as Folio's child on 127.0.0.1 only, with a random port and random Basic-auth
/// login per launch. Its database, installed extensions, caches, temp files and Java home all
/// live inside Folio's data folder. Only the engine program itself (a public, checksum-verified
/// download) is kept separately in ~/Library/Application Support/FolioEngine.
public final class ExtensionEngine: @unchecked Sendable {
    public static let shared = ExtensionEngine()

    public static let version = "v2.4.2366"
    static let jarSHA256 = "af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd"
    static let jarURL = URL(string: "https://github.com/Suwayomi/Suwayomi-Server/releases/download/\(version)/Suwayomi-Server-\(version).jar")!

    public enum State: Equatable, Sendable {
        case stopped, downloading(Double), starting, running, failed(String)
        /// No Java 21+ on this Mac. The app shows an install panel instead of an error line.
        case needsJava
    }

    let lock = NSLock()
    var _state: State = .stopped
    var process: Process?
    var port = 0
    var user = ""
    var pass = ""
    var startTask: Task<Void, Error>?
    public var onStateChange: (@Sendable (State) -> Void)?
    /// FlareSolverr endpoint the engine uses to pass Cloudflare checks. Takes effect on the next engine start.
    public var flareSolverrURL = ""
    /// How long the engine waits for a solver answer. Folio's own solver asks the user, so it needs minutes, not seconds.
    public var flareSolverrTimeoutSeconds = 60
    /// Use the solver's page body when its cookies don't work. Off for Folio's own solver (it returns cookies only).
    public var flareSolverrResponseFallback = true

    public var state: State { lock.withLock { _state } }
    func set(_ s: State) { lock.withLock { _state = s }; onStateChange?(s) }
}

// MARK: - Repos & extensions

public struct ExtensionRepo: Identifiable, Hashable, Sendable {
    public var name: String
    public var indexURL: String
    public var id: String { indexURL }
}

public struct ExtensionInfo: Identifiable, Hashable, Sendable {
    public var pkgName: String
    public var name: String
    public var lang: String
    public var version: String
    public var installed: Bool
    public var hasUpdate: Bool
    public var obsolete: Bool
    public var nsfw: Bool
    public var iconPath: String?
    public var repo: String?
    public var id: String { pkgName }
}

public struct ExtensionSourceInfo: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var lang: String
    public var displayName: String
    public var supportsLatest: Bool
    public var nsfw: Bool
    public var iconPath: String?
    /// Optional so settings saved before this existed still load.
    public var isConfigurable: Bool?
    public init(id: String, name: String, lang: String, displayName: String, supportsLatest: Bool, nsfw: Bool,
                iconPath: String? = nil, isConfigurable: Bool? = nil) {
        self.id = id; self.name = name; self.lang = lang; self.displayName = displayName
        self.supportsLatest = supportsLatest; self.nsfw = nsfw; self.iconPath = iconPath; self.isConfigurable = isConfigurable
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? id
        lang = c.lenient(String.self, .lang) ?? "all"
        displayName = c.lenient(String.self, .displayName) ?? name
        supportsLatest = c.lenient(Bool.self, .supportsLatest) ?? false
        nsfw = c.lenient(Bool.self, .nsfw) ?? false
        iconPath = c.lenient(String.self, .iconPath)
        isConfigurable = c.lenient(Bool.self, .isConfigurable)
    }
}

// MARK: - Tachiyomi / Mihon / Suwayomi backups

/// A series read from a Tachiyomi-family backup, ready to become a library entry.
public struct ImportedSeries: Sendable {
    public var entry: LibraryEntry
    public var categories: [String]
    /// "sourceID|series URL" as the original app knew it, for matching extra data such as last-read times.
    public var key = ""
}

