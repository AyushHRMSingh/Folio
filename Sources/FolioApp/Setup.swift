import FolioCore
import SwiftUI

extension Notification.Name {
    /// Dev only (QA harness): jump the setup to a step.
    static let folioSetupStep = Notification.Name("folio.setup.step")
}

/// First launch: four short questions — extensions, automatic backup, reading style, page width — each saved as it is
/// answered, so quitting half-way loses nothing. Everything here can be changed later in Settings.
struct SetupView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library
    @State private var step = 0
    @State private var repoURL = ""
    @State private var showRepo = false

    private let steps = ["Extensions", "Backups", "Reading", "Page width"]

    var body: some View {
        GeometryReader { g in page(g.size) }
            .background(Theme.bg)
            .contentShape(Rectangle())
            .onTapGesture {}                              // nothing behind the setup can be clicked
            .animation(.easeOut(duration: 0.18), value: step)
            .onReceive(NotificationCenter.default.publisher(for: .folioSetupStep)) { n in
                if let s = n.object as? Int { step = min(max(s, 0), steps.count - 1) }
            }
    }

    /// Fits from the smallest window (760×520) up: the preview shrinks before the questions do.
    private func page(_ size: CGSize) -> some View {
        let compact = size.height < 700
        let avail = size.width - 96
        let gap: CGFloat = avail >= 886 ? 56 : 32
        let column = min(430, max(320, avail * 0.52))
        let previewW = min(400, avail - column - gap)
        let previewH = min(470, size.height - (compact ? 190 : 260))
        return VStack(spacing: 0) {
            header.padding(.top, compact ? 26 : 34)
            HStack(alignment: .top, spacing: gap) {
                ScrollView {
                    Group {
                        switch step {
                        case 0: extensions
                        case 1: backups
                        case 2: reading
                        default: layout
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: column)
                if step >= 2 {
                    DemoPreview(settings: library.settings).frame(width: previewW, height: previewH)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, compact ? 22 : 40)
            footer.frame(maxWidth: column + gap + previewW).padding(.vertical, compact ? 18 : 30)
        }
        .padding(.horizontal, 48)
        .frame(width: size.width, height: size.height)
    }

    // MARK: frame

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                FolioMark().frame(width: 34)
                Text(".folio").font(.system(size: 18, weight: .bold, design: .monospaced)).tracking(-0.6).foregroundStyle(Theme.ink)
            }
            HStack(spacing: 18) {
                ForEach(steps.indices, id: \.self) { i in
                    Text(steps[i].lowercased())
                        .font(.system(size: 12.5, weight: i == step ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(i == step ? Theme.ink : i < step ? Theme.dim : Theme.faint)
                        .overlay(alignment: .bottom) { if i == step { Rectangle().fill(Theme.ink).frame(height: 1.5).offset(y: 4) } }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            TextAction(title: "Skip setup") { finish() }
            Spacer()
            if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.monoLarge) }
            Button(step == steps.count - 1 ? "Start reading" : "Continue") { next() }
                .buttonStyle(.monoLargePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func next() {
        if step < steps.count - 1 { step += 1 } else { finish() }
    }

    private func finish() {
        let url = repoURL.trimmingCharacters(in: .whitespaces)
        if library.settings.extensionsNoticeAccepted != nil, !url.isEmpty {
            app.extensions.app = app
            Task { _ = await app.extensions.addRepo(url) }        // starts the engine in the background
        }
        withAnimation(.easeOut(duration: 0.2)) { library.settings.setupDone = true }
    }

    private func title(_ t: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).font(.folioPageTitle).foregroundStyle(Theme.ink)
            Text(body).font(.folioBody).foregroundStyle(Theme.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }

    // MARK: steps

    private var extensions: some View {
        let on = library.settings.extensionsNoticeAccepted != nil
        return VStack(alignment: .leading, spacing: 0) {
            title("Read from online sources?",
                  "Folio reads folders on this Mac and OPDS servers out of the box. To read from websites it runs extensions in a local engine (Suwayomi, needs Java), only on this Mac.")
            SetRow(label: "Use extensions", hint: on ? "The engine starts the first time you open Extensions." : "You can turn this on later in Extensions.") {
                MonoSwitch(isOn: Binding(get: { on }, set: { library.settings.extensionsNoticeAccepted = $0 ? Date() : nil }))
            }
            if on {
                NoticePoints().font(.system(size: 13)).padding(.top, 18)
                if showRepo {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoField(placeholder: "https://…/index.min.json", text: $repoURL, width: 400)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                        Text("Added when you finish setup.").font(.folioMeta).foregroundStyle(Theme.faint)
                    }
                    .padding(.top, 20)
                } else {
                    TextAction(title: "Add a repository URL…") { showRepo = true }.padding(.top, 20)
                }
            }
        }
    }

    private var backups: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Back up automatically?",
                  "Once a day, when Folio opens, it saves a small file with your library, reading progress, categories and settings. Downloads aren\u{2019}t included.")
            SetRow(label: "Automatic backup", hint: library.settings.autoBackup ? "Folio keeps the last \(library.settings.backupsKept)." : "Off. You can back up by hand in Settings \u{203A} Backup.") {
                MonoSwitch(isOn: $library.settings.autoBackup)
            }
            if library.settings.autoBackup {
                SetRow(label: "Keep the last") { MonoStep(value: $library.settings.backupsKept, range: 1...20) }
            }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("How do you read?", "The default for every series. Any series can have its own mode, set from the reader.")
            ForEach(ReadingMode.allCases) { m in
                ModeRow(mode: m, on: library.settings.defaultMode == m) { library.settings.defaultMode = m }
            }
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("How wide should pages be?",
                  library.settings.defaultMode == .webtoon
                  ? "Narrower pages leave dark margins at the sides — easier on a laptop. The preview shows a strip in a Folio window."
                  : "This sets the width of webtoon strips (vertical scroll). Paged chapters always fit the window.")
            SetRow(label: "Page width") {
                HStack(spacing: 12) {
                    Slider(value: $library.settings.webtoonWidth, in: 0.3...1).controlSize(.small).frame(width: 140)
                    Text("\(Int(library.settings.webtoonWidth * 100))%").font(.folioMono).foregroundStyle(Theme.ink).frame(width: 44, alignment: .trailing)
                }
            }
            SetRow(label: "Gap between pages") {
                MonoChoice(options: [(0.0, "none"), (8.0, "small"), (24.0, "large")], selection: $library.settings.pageGap)
            }
            Text("Zoom is separate: pinch, \u{2318}+ or double-click while reading.").font(.folioMeta).foregroundStyle(Theme.faint).padding(.top, 16)
        }
    }
}

private struct ModeRow: View {
    let mode: ReadingMode
    let on: Bool
    let pick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 14) {
                Image(systemName: mode == .webtoon ? "arrow.down" : mode == .rightToLeft ? "arrow.left" : "arrow.right")
                    .font(.system(size: 14, weight: .medium)).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.label).font(.folioSection)
                    Text(hint).font(.folioMeta).foregroundStyle(Theme.faint)
                }
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundStyle(on ? Theme.ink : Theme.dim)
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(on || hover ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(on ? Theme.ink.opacity(0.5) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.bottom, 8)
    }
    private var hint: String {
        switch mode {
        case .webtoon: "One long strip. Best for webtoons and manhwa."
        case .rightToLeft: "Page by page, right page first. Japanese manga."
        case .leftToRight: "Page by page, left page first. Western comics."
        }
    }
}

// MARK: - demonstration

/// A small Folio window showing a made-up comic in the chosen mode, width and gap.
private struct DemoPreview: View {
    let settings: FolioSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 8, height: 8) }
                Spacer()
                Text("preview").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 12).frame(height: 26)
            GeometryReader { g in
                if settings.defaultMode == .webtoon { strip(g.size) } else { spread(g.size) }
            }
            .clipped()
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: settings.webtoonWidth)
        .animation(.easeOut(duration: 0.2), value: settings.pageGap)
        .animation(.easeOut(duration: 0.2), value: settings.defaultMode)
    }

    /// Webtoon: panels stacked down the middle; the sides are the margins the width leaves.
    private func strip(_ size: CGSize) -> some View {
        let w = size.width * settings.webtoonWidth
        let gap = settings.pageGap * 0.5                              // the preview is about half size
        let heights: [CGFloat] = [0.62, 0.5, 0.7].map { $0 * w * 1.15 }
        return ZStack(alignment: .top) {
            VStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { i in DemoPanel(scene: i).frame(width: w, height: heights[i]) }
            }
            .offset(y: -18)
            marginMarks(size: size, width: w)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func marginMarks(size: CGSize, width w: CGFloat) -> some View {
        let m = (size.width - w) / 2
        return Group {
            if m > 26 {
                HStack(spacing: 0) {
                    Text("margin").frame(width: m)
                    Spacer(minLength: w)
                    Text("margin").frame(width: m)
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Paged: a two-page spread, numbered in the order it's read.
    private func spread(_ size: CGSize) -> some View {
        let rtl = settings.defaultMode == .rightToLeft
        let ph = size.height - 70, pw = min(ph * 0.68, (size.width - 40) / 2)
        return VStack(spacing: 14) {
            HStack(spacing: 2) {
                page(first: !rtl, scenes: rtl ? [3, 4] : [0, 1]).frame(width: pw, height: ph)
                page(first: rtl, scenes: rtl ? [0, 1] : [3, 4]).frame(width: pw, height: ph)
            }
            Label(rtl ? "read right to left" : "read left to right", systemImage: rtl ? "arrow.left" : "arrow.right")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: size.width, height: size.height)
    }

    private func page(first: Bool, scenes: [Int]) -> some View {
        VStack(spacing: 4) {
            DemoPanel(scene: scenes[0])
            DemoPanel(scene: scenes[1])
        }
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 16)
        .background(Color(white: 0.93))
        .overlay(alignment: .bottom) {
            Text(first ? "1" : "2").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.6)).padding(.bottom, 2)
        }
    }
}

/// One panel of Folio's own little demo comic: a night city, a lit window, a cat, a speech bubble.
private struct DemoPanel: View {
    let scene: Int
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            switch scene % 5 {
            case 0: city(ctx, r)
            case 1: window(ctx, r)
            case 2: talk(ctx, r)
            case 3: talk(ctx, r)
            default: city(ctx, r, dawn: true)
            }
            ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(.black), lineWidth: 1.5)
        }
    }

    private func city(_ ctx: GraphicsContext, _ r: CGRect, dawn: Bool = false) {
        let top = dawn ? Color(red: 0.98, green: 0.72, blue: 0.55) : Color(red: 0.12, green: 0.15, blue: 0.32)
        let bottom = dawn ? Color(red: 0.55, green: 0.55, blue: 0.75) : Color(red: 0.32, green: 0.27, blue: 0.5)
        ctx.fill(Path(r), with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: r.origin, endPoint: CGPoint(x: r.minX, y: r.maxY)))
        let moon = CGRect(x: r.width * 0.68, y: r.height * 0.14, width: r.width * 0.14, height: r.width * 0.14)
        ctx.fill(Path(ellipseIn: moon), with: .color(dawn ? Color(red: 1, green: 0.9, blue: 0.7) : Color(white: 0.95)))
        var x: CGFloat = 0, i = 0
        let tones: [Double] = [0.08, 0.13, 0.06, 0.11, 0.09, 0.15]
        while x < r.width {
            let bw = r.width * [0.16, 0.12, 0.2, 0.1, 0.17, 0.13][i % 6]
            let bh = r.height * [0.42, 0.6, 0.34, 0.52, 0.46, 0.3][i % 6]
            let b = CGRect(x: x, y: r.height - bh, width: bw + 1, height: bh)
            ctx.fill(Path(b), with: .color(Color(white: tones[i % 6])))
            for wy in stride(from: b.minY + 8, to: r.height - 6, by: 11) {
                for wx in stride(from: b.minX + 5, to: b.maxX - 6, by: 9) where (Int(wx * 7 + wy * 3) % 5) == 0 {
                    ctx.fill(Path(CGRect(x: wx, y: wy, width: 3, height: 4)), with: .color(Color(red: 1, green: 0.85, blue: 0.45).opacity(0.85)))
                }
            }
            x += bw; i += 1
        }
    }

    private func window(_ ctx: GraphicsContext, _ r: CGRect) {
        ctx.fill(Path(r), with: .color(Color(red: 0.16, green: 0.13, blue: 0.2)))
        let f = r.insetBy(dx: r.width * 0.2, dy: r.height * 0.14)
        ctx.fill(Path(f), with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.5), Color(red: 0.95, green: 0.6, blue: 0.35)]),
                                                startPoint: f.origin, endPoint: CGPoint(x: f.maxX, y: f.maxY)))
        ctx.fill(Path(CGRect(x: f.midX - 1.5, y: f.minY, width: 3, height: f.height)), with: .color(Color(red: 0.16, green: 0.13, blue: 0.2)))
        ctx.fill(Path(CGRect(x: f.minX, y: f.midY - 1.5, width: f.width, height: 3)), with: .color(Color(red: 0.16, green: 0.13, blue: 0.2)))
        // a cat on the sill
        let s = f.width * 0.22, cx = f.midX + f.width * 0.18, base = f.maxY
        var cat = Path(ellipseIn: CGRect(x: cx - s * 0.6, y: base - s * 0.9, width: s * 1.2, height: s * 0.9))
        cat.addEllipse(in: CGRect(x: cx - s * 0.3, y: base - s * 1.45, width: s * 0.62, height: s * 0.6))
        cat.move(to: CGPoint(x: cx - s * 0.28, y: base - s * 1.25)); cat.addLine(to: CGPoint(x: cx - s * 0.2, y: base - s * 1.62)); cat.addLine(to: CGPoint(x: cx - s * 0.05, y: base - s * 1.4))
        cat.move(to: CGPoint(x: cx + 0.3 * s, y: base - s * 1.25)); cat.addLine(to: CGPoint(x: cx + s * 0.24, y: base - s * 1.62)); cat.addLine(to: CGPoint(x: cx + s * 0.08, y: base - s * 1.4))
        ctx.fill(cat, with: .color(Color(white: 0.07)))
        ctx.fill(Path(CGRect(x: f.minX - 6, y: base, width: f.width + 12, height: 5)), with: .color(Color(white: 0.3)))
    }

    private func talk(_ ctx: GraphicsContext, _ r: CGRect) {
        ctx.fill(Path(r), with: .color(Color(white: 0.97)))
        // speed lines from the corner
        for k in 0..<14 {
            let a = Double(k) / 14 * .pi / 2
            var p = Path(); p.move(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - cos(a) * r.width * 1.2, y: r.maxY - sin(a) * r.height * 1.2))
            ctx.stroke(p, with: .color(Color(white: 0.85)), lineWidth: 1)
        }
        let b = CGRect(x: r.width * 0.1, y: r.height * 0.12, width: r.width * 0.62, height: r.height * 0.42)
        var bubble = Path(ellipseIn: b)
        bubble.move(to: CGPoint(x: b.midX - 6, y: b.maxY - 4)); bubble.addLine(to: CGPoint(x: b.midX + 14, y: b.maxY + r.height * 0.14)); bubble.addLine(to: CGPoint(x: b.midX + 8, y: b.maxY - 4))
        ctx.fill(bubble, with: .color(.white))
        ctx.stroke(bubble, with: .color(.black), lineWidth: 1.2)
        for (j, wf) in [0.6, 0.72, 0.4].enumerated() {
            let y = b.minY + b.height * (0.32 + 0.16 * Double(j))
            let w = b.width * wf
            ctx.fill(Path(roundedRect: CGRect(x: b.midX - w / 2, y: y, width: w, height: 3), cornerRadius: 1.5), with: .color(Color(white: 0.25)))
        }
        // a head and shoulders, lower right
        let h = r.height * 0.28, hx = r.width * 0.74, hy = r.height * 0.6
        ctx.fill(Path(ellipseIn: CGRect(x: hx - h / 2, y: hy, width: h, height: h)), with: .color(Color(white: 0.15)))
        ctx.fill(Path(roundedRect: CGRect(x: hx - h, y: hy + h * 0.95, width: h * 2, height: h), cornerRadius: h * 0.4), with: .color(Color(white: 0.15)))
    }
}
