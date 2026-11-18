import Foundation

/// One per-source setting (MangaDex content rating, data saver, image quality…), as the extension describes it.
public struct SourcePreference: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case toggle(Bool)
        case text(String)
        case list(entries: [String], values: [String], current: String)
        case multi(entries: [String], values: [String], current: [String])
    }
    /// Index in the source's preference list; the engine addresses settings by it.
    public let position: Int
    public var key: String
    public var title: String
    public var summary: String
    public var enabled: Bool
    public var kind: Kind
    public var id: Int { position }

    public init(position: Int, key: String = "", title: String, summary: String = "", enabled: Bool = true, kind: Kind) {
        self.position = position; self.key = key; self.title = title; self.summary = summary; self.enabled = enabled; self.kind = kind
    }

    /// The GraphQL `SourcePreferenceChangeInput` for this value.
    var change: [String: Any] {
        switch kind {
        case .toggle(let b): return ["position": position, "checkBoxState": b, "switchState": b]
        case .text(let t): return ["position": position, "editTextState": t]
        case .list(_, _, let c): return ["position": position, "listState": c]
        case .multi(_, _, let c): return ["position": position, "multiSelectState": c]
        }
    }

    /// Parses the engine's JSON. Hidden preferences return nil but still occupy a position.
    static func parse(_ j: [String: Any], position: Int) -> SourcePreference? {
        guard j["visible"] as? Bool ?? true else { return nil }
        let title = j["title"] as? String ?? ""
        let summary = j["summary"] as? String ?? ""
        let key = j["key"] as? String ?? ""
        let enabled = j["enabled"] as? Bool ?? true
        func make(_ k: Kind) -> SourcePreference { SourcePreference(position: position, key: key, title: title, summary: summary, enabled: enabled, kind: k) }
        switch j["__typename"] as? String ?? "" {
        case "CheckBoxPreference": return make(.toggle(j["cbCurrent"] as? Bool ?? j["cbDefault"] as? Bool ?? false))
        case "SwitchPreference": return make(.toggle(j["swCurrent"] as? Bool ?? j["swDefault"] as? Bool ?? false))
        case "EditTextPreference": return make(.text(j["etCurrent"] as? String ?? j["etDefault"] as? String ?? ""))
        case "ListPreference":
            return make(.list(entries: j["entries"] as? [String] ?? [], values: j["entryValues"] as? [String] ?? [],
                              current: j["lsCurrent"] as? String ?? j["lsDefault"] as? String ?? ""))
        case "MultiSelectListPreference":
            return make(.multi(entries: j["entries"] as? [String] ?? [], values: j["entryValues"] as? [String] ?? [],
                               current: j["msCurrent"] as? [String] ?? j["msDefault"] as? [String] ?? []))
        default: return nil
        }
    }

    /// GraphQL selection shared by reading and updating (aliases avoid the engine's same-name/different-type conflict).
    static let selection = """
        __typename
        ... on CheckBoxPreference { title summary key visible enabled cbCurrent: currentValue cbDefault: default }
        ... on SwitchPreference { title summary key visible enabled swCurrent: currentValue swDefault: default }
        ... on EditTextPreference { title summary key visible enabled etCurrent: currentValue etDefault: default }
        ... on ListPreference { title summary key visible enabled entries entryValues lsCurrent: currentValue lsDefault: default }
        ... on MultiSelectListPreference { title summary key visible enabled entries entryValues msCurrent: currentValue msDefault: default }
        """

    static func parseAll(_ raw: [[String: Any]]) -> [SourcePreference] {
        raw.enumerated().compactMap { parse($1, position: $0) }
    }
}
