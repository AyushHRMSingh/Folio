import CommonCrypto
import Foundation

/// How long Folio may be in the background before it asks for the PIN again.
public enum LockAfter: Int, Codable, CaseIterable, Sendable {
    case immediately = 0, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900, oneHour = 3600
    public var label: String {
        switch self {
        case .immediately: "at once"
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .oneHour: "1 hour"
        }
    }
}

/// Folio's privacy lock: a PIN (stored only as a salted, slow hash in Folio's own settings file, never the
/// Keychain) and optionally Touch ID — or Touch ID alone (no PIN: empty hash, length 0). It keeps other people at this Mac out of your reading; it is not encryption.
public struct AppLock: Codable, Equatable, Sendable {
    public var salt: String
    public var hash: String
    /// Digits in the PIN, so the lock screen can check as soon as the last one is typed.
    public var length: Int
    public var touchID = true
    public var after: LockAfter = .immediately

    public static let digits = 4...8
    static let rounds: UInt32 = 200_000

    /// False for a Touch ID–only lock.
    public var usesPIN: Bool { !hash.isEmpty }

    /// Touch ID only, no PIN. The Mac's password is the fallback.
    public static func touchIDOnly(after: LockAfter = .immediately) -> AppLock {
        AppLock(salt: "", hash: "", length: 0, touchID: true, after: after)
    }

    /// Nil when the PIN isn't 4–8 digits.
    public static func make(pin: String) -> AppLock? {
        guard isValid(pin) else { return nil }
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let s = Data(salt).base64EncodedString()
        return AppLock(salt: s, hash: derive(pin, salt: s), length: pin.count)
    }

    public static func isValid(_ pin: String) -> Bool { digits.contains(pin.count) && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber) }

    public func matches(_ pin: String) -> Bool {
        guard usesPIN else { return false }
        let a = Array(Self.derive(pin, salt: salt).utf8), b = Array(hash.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0       // same time whatever matches
    }

    /// Same PIN, new salt; keeps the other options.
    public func withPIN(_ pin: String) -> AppLock? {
        guard var n = Self.make(pin: pin) else { return nil }
        n.touchID = touchID; n.after = after
        return n
    }

    static func derive(_ pin: String, salt: String) -> String {
        let s = Data(base64Encoded: salt) ?? Data()
        var out = [UInt8](repeating: 0, count: 32)
        let p = Array(pin.utf8)
        let ok = s.withUnsafeBytes { sb in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, p.count,
                                 sb.bindMemory(to: UInt8.self).baseAddress, s.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        return ok == kCCSuccess ? Data(out).base64EncodedString() : ""
    }

    public init(salt: String, hash: String, length: Int, touchID: Bool = true, after: LockAfter = .immediately) {
        self.salt = salt; self.hash = hash; self.length = length; self.touchID = touchID; self.after = after
    }

    enum CodingKeys: String, CodingKey { case salt, hash, length, touchID, after }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        salt = try c.decode(String.self, forKey: .salt)
        hash = try c.decode(String.self, forKey: .hash)
        length = c.lenient(Int.self, .length) ?? 0
        touchID = c.lenient(Bool.self, .touchID) ?? true
        after = c.lenient(LockAfter.self, .after) ?? .immediately
    }
}
