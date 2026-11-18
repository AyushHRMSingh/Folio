import Foundation

/// Groups pages into on-screen spreads for the double-page reader.
public enum PageSpreads {
    /// Each spread is one or two page indices in reading order. A wide page (already a spread in the
    /// source) stands alone, and so does the first page when it is a cover.
    public static func layout(count: Int, isWide: (Int) -> Bool, firstAlone: Bool) -> [[Int]] {
        var out: [[Int]] = []
        var i = 0
        while i < count {
            if (i == 0 && firstAlone) || isWide(i) { out.append([i]); i += 1 }
            else if i + 1 < count, !isWide(i + 1) { out.append([i, i + 1]); i += 2 }
            else { out.append([i]); i += 1 }
        }
        return out
    }

    /// Which spread shows page `page`.
    public static func spread(containing page: Int, in layout: [[Int]]) -> Int {
        layout.firstIndex { $0.contains(page) } ?? max(0, layout.count - 1)
    }

    /// A page this much wider than tall is treated as a two-page spread.
    public static let wideThreshold = 1.15
}
