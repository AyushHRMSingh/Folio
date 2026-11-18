import FolioCore
import SwiftUI

/// The source's own filters, drawn in Folio's style. Edits are local until Apply.
struct FilterPanel: View {
    @Binding var filters: [SourceFilter]
    let apply: () -> Void
    @State private var open: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach($filters) { $f in row($f) }
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                TextAction(title: "reset", disabled: filters.activeCount == 0) { filters = filters.reset() }
                Spacer()
                Text(filters.activeCount == 0 ? "no filters" : "\(filters.activeCount) active")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.faint)
                Spacer()
                Button("Apply", action: apply).buttonStyle(.monoPrimary)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 440, height: 540)
        .background(Theme.bg)
        .onAppear { open = Set(filters.filter { $0.activeCount > 0 }.map(\.id)) }     // groups with something set start open
    }

    func row(_ f: Binding<SourceFilter>) -> AnyView { AnyView(rowContent(f)) }     // type-erased: groups nest

    @ViewBuilder func rowContent(_ f: Binding<SourceFilter>) -> some View {
        switch f.wrappedValue.kind {
        case .header:
            Eyebrow(f.wrappedValue.name).padding(.top, 18).padding(.bottom, 6)
        case .separator:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 10)
        case .checkbox(let on):
            SetRow(label: f.wrappedValue.name) { MonoSwitch(isOn: Binding(get: { on }, set: { f.wrappedValue.kind = .checkbox($0) })) }
        case .tristate:
            SetRow(label: f.wrappedValue.name) { Tag(filter: f) }
        case .text(let t):
            SetRow(label: f.wrappedValue.name) {
                MonoField(placeholder: "…", text: Binding(get: { t }, set: { f.wrappedValue.kind = .text($0) }), width: 200)
            }
        case .select(let values, let i):
            SetRow(label: f.wrappedValue.name) {
                Menu {
                    ForEach(values.indices, id: \.self) { k in
                        Button { f.wrappedValue.kind = .select(values: values, index: k) } label: {
                            if k == i { Label(values[k], systemImage: "checkmark") } else { Text(values[k]) }
                        }
                    }
                } label: { menuLabel(values.indices.contains(i) ? values[i] : "—") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        case .sort(let values, let i, let asc):
            SetRow(label: f.wrappedValue.name) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(values.indices, id: \.self) { k in
                            Button { f.wrappedValue.kind = .sort(values: values, index: k, ascending: asc) } label: {
                                if k == i { Label(values[k], systemImage: "checkmark") } else { Text(values[k]) }
                            }
                        }
                    } label: { menuLabel(i.flatMap { values.indices.contains($0) ? values[$0] : nil } ?? "—") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Button { f.wrappedValue.kind = .sort(values: values, index: i ?? 0, ascending: !asc) } label: {
                        Text(asc ? "↑" : "↓").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain).help(asc ? "Ascending" : "Descending")
                }
            }
        case .group(let kids):
            let isOpen = open.contains(f.wrappedValue.id)
            VStack(alignment: .leading, spacing: 0) {
                Button { if isOpen { open.remove(f.wrappedValue.id) } else { open.insert(f.wrappedValue.id) } } label: {
                    HStack {
                        Text(f.wrappedValue.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                        if f.wrappedValue.activeCount > 0 { Chip(text: "\(f.wrappedValue.activeCount)", filled: true) }
                        Spacer()
                        Text(isOpen ? "−" : "+").font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                    .padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isOpen {
                    let tags = kids.allSatisfy { if case .checkbox = $0.kind { return true } else if case .tristate = $0.kind { return true } else { return false } }
                    if tags {
                        FlowLayout(spacing: 6) {
                            ForEach(groupKids(f)) { $k in Tag(filter: $k, chip: true) }
                        }
                        .padding(.bottom, 12)
                    } else {
                        ForEach(groupKids(f)) { $k in row($k) }
                    }
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    func groupKids(_ f: Binding<SourceFilter>) -> Binding<[SourceFilter]> {
        Binding(get: { if case .group(let k) = f.wrappedValue.kind { return k } else { return [] } },
                set: { f.wrappedValue.kind = .group($0) })
    }

    func menuLabel(_ t: String) -> some View {
        HStack(spacing: 5) {
            Text(t).font(.system(size: 12, design: .monospaced))
            Text("▾").font(.system(size: 9))
        }
        .foregroundStyle(Theme.ink).padding(.horizontal, 9).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
    }
}

/// A checkbox or tri-state shown as a tag: click to include, again to exclude (tri-state), again to clear.
private struct Tag: View {
    @Binding var filter: SourceFilter
    var chip = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if chip == false || mark != "" { Text(mark).font(.system(size: 11, weight: .bold, design: .monospaced)) }
                if chip { Text(filter.name).font(.system(size: 12)).strikethrough(excluded) }
            }
            .foregroundStyle(on ? Theme.onInk : (excluded ? Theme.ink : Theme.dim))
            .padding(.horizontal, chip ? 10 : 9).padding(.vertical, chip ? 5 : 4)
            .background(on ? Theme.ink : Color.clear, in: Capsule())
            .overlay { if !on { Capsule().strokeBorder(excluded ? Theme.ink : Theme.line, style: StrokeStyle(lineWidth: 1, dash: excluded ? [3, 2] : [])) } }
        }
        .buttonStyle(.plain)
    }

    var on: Bool {
        switch filter.kind { case .checkbox(let b): b; case .tristate(let s): s == .include; default: false }
    }
    var excluded: Bool { if case .tristate(.exclude) = filter.kind { return true } else { return false } }
    var mark: String {
        switch filter.kind { case .tristate(let s): s == .include ? "+" : (s == .exclude ? "−" : (chip ? "" : "·")); case .checkbox(let b): b ? "✓" : ""; default: "" }
    }
    func tap() {
        switch filter.kind {
        case .checkbox(let b): filter.kind = .checkbox(!b)
        case .tristate(let s): filter.kind = .tristate(s.next)
        default: break
        }
    }
}
