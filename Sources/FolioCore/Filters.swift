import Foundation

/// One control in a source's filter panel (genres, status, sort order…). Sources define their own;
/// Folio draws whatever the extension describes.
public struct SourceFilter: Identifiable, Sendable, Equatable {
    public enum TriState: String, Sendable { case ignore = "IGNORE", include = "INCLUDE", exclude = "EXCLUDE"
        public var next: TriState { switch self { case .ignore: .include; case .include: .exclude; case .exclude: .ignore } }
    }
    public enum Kind: Sendable, Equatable {
        case header, separator
        case checkbox(Bool)
        case tristate(TriState)
        case text(String)
        case select(values: [String], index: Int)
        case sort(values: [String], index: Int?, ascending: Bool)
        case group([SourceFilter])
    }
    public let id = UUID()
    public var name: String
    public var kind: Kind
    /// What the extension started with, so "reset" and "active" can be computed.
    public var initial: Kind

    public init(name: String, kind: Kind) { self.name = name; self.kind = kind; self.initial = kind }

    public static func == (a: SourceFilter, b: SourceFilter) -> Bool { a.name == b.name && a.kind == b.kind }

    /// Differs from its starting value (a group counts its children).
    public var activeCount: Int {
        switch kind {
        case .header, .separator: return 0
        case .group(let kids): return kids.reduce(0) { $0 + $1.activeCount }
        default: return kind == initial ? 0 : 1
        }
    }
    public func reset() -> SourceFilter {
        var f = self
        if case .group(let kids) = kind { f.kind = .group(kids.map { $0.reset() }) } else { f.kind = initial }
        return f
    }
}

public extension Array where Element == SourceFilter {
    var activeCount: Int { reduce(0) { $0 + $1.activeCount } }
    func reset() -> [SourceFilter] { map { $0.reset() } }

    /// The GraphQL `FilterChangeInput` list. The engine keeps filter state between calls, so every
    /// control is sent explicitly — otherwise a filter you cleared would stay applied.
    var changes: [[String: Any]] {
        var out: [[String: Any]] = []
        for (i, f) in enumerated() {
            if case .group(let kids) = f.kind {
                for (j, k) in kids.enumerated() { if let c = k.change(at: j) { out.append(["position": i, "groupChange": c]) } }
            } else if let c = f.change(at: i) { out.append(c) }
        }
        return out
    }
}

extension SourceFilter {
    func change(at position: Int) -> [String: Any]? {
        switch kind {
        case .header, .separator, .group: return nil
        case .checkbox(let on): return ["position": position, "checkBoxState": on]
        case .tristate(let s): return ["position": position, "triState": s.rawValue]
        case .text(let t): return ["position": position, "textState": t]
        case .select(_, let i): return ["position": position, "selectState": i]
        case .sort(_, let i, let asc): return i.map { ["position": position, "sortState": ["index": $0, "ascending": asc]] }
        }
    }

    /// Parses the engine's JSON (`__typename` plus the fields of each filter type).
    static func parse(_ j: [String: Any]) -> SourceFilter? {
        let name = j["name"] as? String ?? ""
        switch j["__typename"] as? String ?? "" {
        case "HeaderFilter": return SourceFilter(name: name, kind: .header)
        case "SeparatorFilter": return SourceFilter(name: name, kind: .separator)
        case "CheckBoxFilter": return SourceFilter(name: name, kind: .checkbox(j["cbDefault"] as? Bool ?? false))
        case "TriStateFilter": return SourceFilter(name: name, kind: .tristate(TriState(rawValue: j["triDefault"] as? String ?? "") ?? .ignore))
        case "TextFilter": return SourceFilter(name: name, kind: .text(j["textDefault"] as? String ?? ""))
        case "SelectFilter":
            return SourceFilter(name: name, kind: .select(values: j["values"] as? [String] ?? [], index: j["selDefault"] as? Int ?? 0))
        case "SortFilter":
            let d = j["sortDefault"] as? [String: Any]
            return SourceFilter(name: name, kind: .sort(values: j["values"] as? [String] ?? [], index: d?["index"] as? Int,
                                                        ascending: d?["ascending"] as? Bool ?? false))
        case "GroupFilter":
            return SourceFilter(name: name, kind: .group((j["filters"] as? [[String: Any]] ?? []).compactMap(parse)))
        default: return nil
        }
    }
}
