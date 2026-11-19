import FolioCore
import SwiftUI

/// The one reading-settings panel (D2). With a comic it edits *that comic's* settings — each row it has changed
/// shows "reset" — and offers to make them the default; with no comic it edits the defaults for every comic.
/// Used by the reader (⚙ / S), the series page ("Reading settings…") and Settings › Reader defaults.
struct ReadingSettingsPanel: View {
    @ObservedObject var library: Library
    /// nil = edit the defaults.
    let seriesID: String?
    /// The reader passes its own mode switch so the open chapter re-lays out at once.
    var onMode: ((ReadingMode) -> Void)? = nil

    var scoped: Bool { seriesID.flatMap { library.entry($0) } != nil }
    var mode: ReadingMode { seriesID.map { library.mode(for: $0) } ?? library.settings.defaultMode }

    var body: some View {
        VStack(spacing: 0) {
            if seriesID != nil && !scoped {
                Text("This comic isn't in your library or history, so changes here apply to every comic.")
                    .font(.system(size: 13)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            }
            Row("Reading mode", own: scoped && library.entry(seriesID!)?.readingMode != nil,
                reset: { library.setMode(seriesID!, nil); onMode?(library.mode(for: seriesID!)) }) {
                MonoChoice(options: ReadingMode.allCases.map { ($0, $0.shortLabel.lowercased()) },
                           selection: Binding(get: { mode }, set: { m in
                               if let onMode { onMode(m) }
                               else if let id = seriesID, scoped { library.setMode(id, m) }
                               else { library.settings.defaultMode = m }
                           }))
            }
            if !scoped || mode == .webtoon {
                if !scoped { group("Vertical scroll (webtoon)") }
                Row("Width", own: own(\.webtoonWidth), reset: reset(\.webtoonWidth)) {
                    HStack(spacing: 12) {
                        Slider(value: bind(\.webtoonWidth, \.webtoonWidth), in: 0.3...1).controlSize(.small).frame(width: 130)
                        Text("\(Int(value(\.webtoonWidth, \.webtoonWidth) * 100))%").font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
                    }
                }
                Row("Gap between pages", own: own(\.pageGap), reset: reset(\.pageGap)) {
                    MonoChoice(options: [(0.0, "none"), (8.0, "small"), (24.0, "large")], selection: bind(\.pageGap, \.pageGap))
                }
                Row("Auto-scroll speed", own: own(\.autoScrollSpeed), reset: reset(\.autoScrollSpeed)) {
                    Slider(value: bind(\.autoScrollSpeed, \.autoScrollSpeed), in: 30...600).controlSize(.small).frame(width: 150)
                }
                Row("Continuous scrolling between chapters", own: own(\.seamlessChapters), reset: reset(\.seamlessChapters)) {
                    MonoSwitch(isOn: bind(\.seamlessChapters, \.seamlessChapters))
                }
            }
            if !scoped || mode != .webtoon {
                if !scoped { group("Pages") }
                Row("Tap zones", own: own(\.tapZones), reset: reset(\.tapZones)) {
                    MonoChoice(options: TapZones.allCases.map { ($0, $0.label.lowercased()) }, selection: bind(\.tapZones, \.tapZones))
                }
                Row("Swap back and forward", own: own(\.invertTapZones), reset: reset(\.invertTapZones)) {
                    MonoSwitch(isOn: bind(\.invertTapZones, \.invertTapZones))
                }
                Row("Two pages at a time", own: own(\.doublePage), reset: reset(\.doublePage)) {
                    MonoSwitch(isOn: bind(\.doublePage, \.doublePage))
                }
                if value(\.doublePage, \.doublePage) {
                    Row("First page alone (cover)", own: own(\.doubleFirstAlone), reset: reset(\.doubleFirstAlone)) {
                        MonoSwitch(isOn: bind(\.doubleFirstAlone, \.doubleFirstAlone))
                    }
                } else {
                    Row("Split wide pages in two", own: own(\.splitWidePages), reset: reset(\.splitWidePages)) {
                        MonoSwitch(isOn: bind(\.splitWidePages, \.splitWidePages))
                    }
                }
                Row("Crop white and black margins", own: own(\.cropBorders), reset: reset(\.cropBorders)) {
                    MonoSwitch(isOn: bind(\.cropBorders, \.cropBorders))
                }
            }
            if !scoped { group("Look") }
            Row("Background", own: own(\.readerBackground), reset: reset(\.readerBackground)) {
                MonoChoice(options: [(ReaderBackground.black, "black"), (.gray, "gray"), (.white, "white"), (.auto, "auto")],
                           selection: bind(\.readerBackground, \.readerBackground))
            }
            if scoped, let id = seriesID {
                HStack(spacing: 12) {
                    TextAction(title: "Use for all comics", disabled: !library.hasOwnReaderPrefs(id)) { library.useReaderPrefsAsDefault(id) }
                        .help("Make these settings the default for every comic")
                    TextAction(title: "Reset this comic", disabled: !library.hasOwnReaderPrefs(id)) {
                        library.setMode(id, nil)
                        for r in Self.allResets { r(library, id) }
                        onMode?(library.mode(for: id))
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
            }
            group(scoped ? "For every comic" : "Reading")
            SetRow(label: "Skip chapters already read") { MonoSwitch(isOn: $library.settings.skipReadChapters) }
            SetRow(label: "Show page number") { MonoSwitch(isOn: $library.settings.showPageNumber) }
            SetRow(label: "Keep screen awake") { MonoSwitch(isOn: $library.settings.keepAwake) }
        }
    }

    // MARK: helpers

    func value<T: Equatable>(_ o: WritableKeyPath<ReaderOverrides, T?>, _ d: WritableKeyPath<FolioSettings, T>) -> T {
        library.readerOverride(seriesID, o) ?? library.settings[keyPath: d]
    }
    func bind<T: Equatable>(_ o: WritableKeyPath<ReaderOverrides, T?>, _ d: WritableKeyPath<FolioSettings, T>) -> Binding<T> {
        Binding(get: { value(o, d) }, set: { library.setReaderPref(scoped ? seriesID : nil, o, d, $0) })
    }
    func own<T>(_ o: WritableKeyPath<ReaderOverrides, T?>) -> Bool { scoped && library.readerOverride(seriesID, o) != nil }
    func reset<T>(_ o: WritableKeyPath<ReaderOverrides, T?>) -> () -> Void { { if let id = seriesID { library.resetReaderPref(id, o) } } }

    static let allResets: [(Library, String) -> Void] = [
        { $0.resetReaderPref($1, \.webtoonWidth) }, { $0.resetReaderPref($1, \.pageGap) }, { $0.resetReaderPref($1, \.autoScrollSpeed) },
        { $0.resetReaderPref($1, \.seamlessChapters) }, { $0.resetReaderPref($1, \.tapZones) }, { $0.resetReaderPref($1, \.invertTapZones) },
        { $0.resetReaderPref($1, \.doublePage) }, { $0.resetReaderPref($1, \.doubleFirstAlone) }, { $0.resetReaderPref($1, \.splitWidePages) },
        { $0.resetReaderPref($1, \.cropBorders) }, { $0.resetReaderPref($1, \.readerBackground) },
    ]

    func group(_ t: String) -> some View {
        HStack { Eyebrow(t); Spacer() }.padding(.top, 18).padding(.bottom, 2)
    }

    /// A settings row that marks a value this comic has changed, with a way back to the default.
    struct Row<Control: View>: View {
        let label: String
        let own: Bool
        let reset: () -> Void
        @ViewBuilder let control: () -> Control
        init(_ label: String, own: Bool, reset: @escaping () -> Void, @ViewBuilder control: @escaping () -> Control) {
            self.label = label; self.own = own; self.reset = reset; self.control = control
        }
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 25) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 14.5)).foregroundStyle(Theme.ink)
                    if own {
                        Button(action: reset) {
                            Text("this comic only · reset").font(.system(size: 13)).foregroundStyle(Theme.dim).underline()
                        }
                        .buttonStyle(.plain).help("Go back to the default for every comic")
                    }
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

/// The panel as a sheet, for the series page.
struct ReadingSettingsSheet: View {
    @ObservedObject var library: Library
    let series: Series
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Reading settings")
                    Text(series.title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.mono).keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 6)
            ScrollView { ReadingSettingsPanel(library: library, seriesID: series.id) }
        }
        .padding(20).frame(width: 440, height: 520).background(Theme.bg)
    }
}
