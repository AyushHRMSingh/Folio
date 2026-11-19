import SwiftUI

/// The Folio logo (the app icon: four leather-bound spines on a walnut shelf), drawn natively from the same
/// coordinates as `Resources/AppIcon.svg` so it stays crisp at any size and needs no bundled image.
struct FolioMark: View {
    /// true = the full app icon (dark rounded tile); false = just the books on their shelf.
    var tile = false

    /// The books and shelf, in icon coordinates before the icon's own scaling.
    static let booksBox = CGRect(x: 150, y: 200, width: 724, height: 672)

    var body: some View {
        Canvas { ctx, size in
            if !tile {
                // Fit just the books into the frame, centred, and skip the tile.
                let b = Self.booksBox
                let s = min(size.width / b.width, size.height / b.height)
                ctx.translateBy(x: (size.width - b.width * s) / 2, y: (size.height - b.height * s) / 2)
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: -b.minX, y: -b.minY)
                Self.drawBooks(ctx)
                return
            }
            let s = min(size.width, size.height) / 1024
            ctx.scaleBy(x: s, y: s)
            func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double = 0, _ c: Color) {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(c))
            }
            func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, fill: Color, stroke: Color, _ lw: Double) {
                let p = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
                ctx.fill(p, with: .color(fill)); ctx.stroke(p, with: .color(stroke), lineWidth: lw)
            }
            // tile
            rect(0, 0, 1024, 1024, 230, Color(hex: 0x12100E))
            ctx.stroke(Path(roundedRect: CGRect(x: 2, y: 2, width: 1020, height: 1020), cornerRadius: 228), with: .color(Color(hex: 0x2C2722)), lineWidth: 4)
            // books, scaled 1.18 about the centre and nudged up (as in the SVG)
            ctx.translateBy(x: 512, y: 515); ctx.scaleBy(x: 1.18, y: 1.18); ctx.translateBy(x: -512, y: -536)
            Self.drawBooks(ctx)
        }
        .aspectRatio(tile ? 1 : Self.booksBox.width / Self.booksBox.height, contentMode: .fit)
        .accessibilityLabel("Folio")
    }

    /// The four spines and the shelf, in icon coordinates.
    static func drawBooks(_ ctx: GraphicsContext) {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double = 0, _ c: Color) {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(c))
        }
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, fill: Color, stroke: Color, _ lw: Double) {
            let p = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
            ctx.fill(p, with: .color(fill)); ctx.stroke(p, with: .color(stroke), lineWidth: lw)
        }
        let shade = Color.black.opacity(0.18)
        let gold = Color(hex: 0xC9A24A), gold2 = Color(hex: 0xD4AE55), gold3 = Color(hex: 0xE0BE6A)
        // oxblood
        rect(193, 280, 150, 550, 12, Color(hex: 0x7A1F24)); rect(193, 280, 18, 550, 0, shade)
        for y in [335.0, 362, 737, 764] { rect(207, y, 122, 13, 0, gold) }
        box(219, 414, 98, 130, 5, fill: Color(hex: 0x2A0D0F), stroke: gold, 6)
        rect(243, 452, 50, 9, 2, gold); rect(251, 476, 34, 9, 2, gold)
        // green
        rect(357, 360, 130, 470, 12, Color(hex: 0x1E4A3A)); rect(357, 360, 16, 470, 0, shade)
        for y in [410.0, 435, 740, 765] { rect(371, y, 102, 12, 0, gold) }
        box(383, 484, 78, 108, 5, fill: Color(hex: 0x0E2219), stroke: gold, 5)
        // navy
        rect(501, 200, 175, 630, 14, Color(hex: 0x1F2E55)); rect(501, 200, 20, 630, 0, shade)
        for y in [262.0, 291, 735, 764] { rect(517, y, 143, 14, 0, gold2) }
        box(529, 350, 119, 156, 6, fill: Color(hex: 0x0F1730), stroke: gold2, 6)
        rect(553, 388, 71, 10, 2, gold2); rect(563, 414, 51, 10, 2, gold2); rect(572, 456, 33, 10, 2, gold2)
        // cognac
        rect(690, 310, 140, 520, 12, Color(hex: 0x8C5426)); rect(690, 310, 17, 520, 0, shade)
        for y in [364.0, 391, 737, 764] { rect(704, y, 112, 13, 0, gold3) }
        box(716, 444, 88, 118, 5, fill: Color(hex: 0x4A2A12), stroke: gold3, 5)
        // shelf
        rect(150, 830, 724, 30, 7, Color(hex: 0x6B4426)); rect(150, 830, 724, 7, 3, Color(hex: 0x8A5C36))
        rect(172, 860, 680, 12, 4, Color(hex: 0x3A2414))
    }

}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
