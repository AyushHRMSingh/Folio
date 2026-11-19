import AppKit
import SwiftUI

/// Folio's look: pure black and white. One ink colour, three greys, hairlines, no shadows, no
/// materials, no gradients — flat layers are what keep scrolling at the display's full refresh rate.
enum Theme {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func w(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
    private static func k(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }

    /// Window background.
    static let bg = dynamic(dark: .black, light: .white)
    /// Raised surfaces: cards, rows, fields.
    static let surface = dynamic(dark: NSColor(white: 0.075, alpha: 1), light: NSColor(white: 0.955, alpha: 1))
    static let surfaceHover = dynamic(dark: NSColor(white: 0.12, alpha: 1), light: NSColor(white: 0.92, alpha: 1))
    /// Hairline borders and dividers.
    static let line = dynamic(dark: w(0.11), light: k(0.10))
    /// Text and icons: ink, then two quieter greys.
    static let ink = dynamic(dark: w(0.96), light: k(0.94))
    static let dim = dynamic(dark: w(0.56), light: k(0.55))
    static let faint = dynamic(dark: w(0.34), light: k(0.34))
    /// Text on top of an ink-coloured fill.
    static let onInk = dynamic(dark: .black, light: .white)

    static let nsBg = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white }

    // Metrics
    static let radius: CGFloat = 8
    static let coverRadius: CGFloat = 3
    static let pad: CGFloat = 28
}

// MARK: - Type

extension Font {
    static func folio(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static let pageTitle = Font.system(size: 28, weight: .semibold)
    static let rowTitle = Font.system(size: 14.5, weight: .medium)
    static let meta = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 11.5, weight: .semibold)

    // Type scale. Monospace is only for numbers and metadata, never for prose or titles.
    static let folioTitle = Font.system(size: 36, weight: .light)
    static let folioPageTitle = Font.system(size: 32, weight: .light)
    static let folioSection = Font.system(size: 14.5, weight: .medium)
    static let folioBody = Font.system(size: 14.5)
    static let folioMeta = Font.system(size: 13)
    static let folioLabel = Font.system(size: 11.5, weight: .semibold)
    static let folioMono = Font.system(size: 13.5, design: .monospaced)
}

/// Small uppercase section label.
struct Eyebrow: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.label).tracking(1.1).foregroundStyle(Theme.dim)
    }
}

// MARK: - Buttons

struct MonoButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary
    var large = false
    @State private var hover = false

    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: large ? 13.5 : 12.5, weight: .medium))
            .padding(.horizontal, large ? 18 : 12).padding(.vertical, large ? 9 : 6)
            .foregroundStyle(kind == .primary ? Theme.onInk : Theme.ink)
            .background(fill(pressed: c.isPressed), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay {
                if kind == .secondary { RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line) }
            }
            .opacity(c.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: return Theme.ink
        case .secondary: return hover ? Theme.surfaceHover : Theme.surface
        case .ghost: return hover ? Theme.surface : .clear
        }
    }
}

extension ButtonStyle where Self == MonoButtonStyle {
    static var monoPrimary: MonoButtonStyle { .init(kind: .primary) }
    static var monoLargePrimary: MonoButtonStyle { .init(kind: .primary, large: true) }
    static var mono: MonoButtonStyle { .init(kind: .secondary) }
    static var monoLarge: MonoButtonStyle { .init(kind: .secondary, large: true) }
    static var monoGhost: MonoButtonStyle { .init(kind: .ghost) }
}

/// Round icon button used in toolbars and the reader.
struct IconButton: View {
    let icon: String
    var help: String = ""
    var active = false
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14.5, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Theme.onInk : Theme.ink)
                .background(active ? Theme.ink : (hover ? Theme.surfaceHover : Theme.surface), in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Small filled or outlined count/label pill.
struct Chip: View {
    let text: String
    var filled = false
    var body: some View {
        Text(text).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(filled ? Theme.onInk : Theme.dim)
            .background(filled ? Theme.ink : Color.clear, in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(Theme.line) } }
    }
}

/// Thin progress line.
struct Hairline: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.line)
                Rectangle().fill(Theme.ink).frame(width: g.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 2)
        .clipShape(Capsule())
    }
}


// MARK: - Settings-style rows

/// A titled block of rows.
struct SetSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(title).padding(.bottom, 4)
            content()
        }
        .padding(.top, 36)
    }
}

/// `label ........ control`, with an optional quiet hint under the label and a hairline below.
struct SetRow<Control: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let control: () -> Control
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 25) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 14.5)).foregroundStyle(Theme.ink)
                if let hint { Text(hint).font(.system(size: 13)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Pick one: words in a row, the chosen one underlined.
struct MonoChoice<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 20) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].0 == selection
                Button { selection = options[i].0 } label: {
                    Text(options[i].1.lowercased()).font(.system(size: 13.5, weight: on ? .semibold : .regular, design: .monospaced))
                        .lineLimit(1).fixedSize()          // an option never wraps onto two lines
                        .foregroundStyle(on ? Theme.ink : Theme.dim)
                        .overlay(alignment: .bottom) { if on { Rectangle().fill(Theme.ink).frame(height: 1.5).offset(y: 4) } }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MonoSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.ink : Theme.surface)
                Capsule().strokeBorder(isOn ? Theme.ink : Theme.line, lineWidth: 1)
                Circle().fill(isOn ? Theme.onInk : Theme.dim)
                    .frame(width: 12, height: 12).padding(.horizontal, 3)
            }
            .frame(width: 30, height: 18)
            .animation(.easeOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct MonoStep: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack(spacing: 15) {
            Button { value = max(range.lowerBound, value - 1) } label: { Text("−") }.buttonStyle(.plain)
            Text("\(value)").frame(minWidth: 18)
            Button { value = min(range.upperBound, value + 1) } label: { Text("+") }.buttonStyle(.plain)
        }
        .font(.system(size: 14.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink)
    }
}

/// Small text action — same look as the Library header tools.
struct TextAction: View {
    let title: String
    var destructive = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14)).lineLimit(1).fixedSize()
                .foregroundStyle(disabled ? Theme.faint : (destructive ? Color.red.opacity(hover ? 1 : 0.85) : (hover ? Theme.ink : Theme.dim)))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(hover && !disabled ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).onHover { hover = $0 }
    }
}

/// Label for a header menu button (sans, chevron, hover background), matching the Library header.
struct ToolMenuLabel: View {
    let title: String
    var chevron = true
    var icon: String? = nil
    @State private var hover = false
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
            if icon == nil { Text(title).font(.system(size: 14)).lineLimit(1).fixedSize() }
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .foregroundStyle(hover ? Theme.ink : Theme.dim)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Borderless single-line field.
/// The one back control: same look, same place (top-left of the page) everywhere.
struct BackLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 13.5))
            }
            .foregroundStyle(Theme.dim).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back (Esc)")
    }
}

struct MonoField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var width: CGFloat = 280
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.ink)
        .frame(width: width)
    }
}
