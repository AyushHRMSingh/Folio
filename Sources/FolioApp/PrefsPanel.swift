import FolioCore
import SwiftUI

/// A source's own settings. Every change is saved straight away (the engine owns them).
struct PrefsPanel: View {
    let source: Source
    var changed: () -> Void = {}
    @State private var prefs: [SourcePreference] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var drafts: [Int: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !loaded {
                    HStack { ProgressView().controlSize(.small); Text("Loading…").font(.folioMeta).foregroundStyle(Theme.dim) }.padding(.top, 24)
                } else if prefs.isEmpty {
                    Text("This source has no settings.").font(.folioBody).foregroundStyle(Theme.dim).padding(.top, 24)
                }
                ForEach(prefs) { p in row(p) }
                if let failure { Text(failure).font(.folioMeta).foregroundStyle(Theme.dim).padding(.top, 12) }
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        }
        .frame(width: 420, height: 460)
        .background(Theme.bg)
        .task {
            do { prefs = try await source.preferences() } catch { failure = error.localizedDescription }
            loaded = true
        }
    }

    func save(_ p: SourcePreference) {
        if let i = prefs.firstIndex(where: { $0.position == p.position }) { prefs[i] = p }       // show it at once
        Task {
            do { prefs = try await source.setPreference(p); failure = nil; changed() }
            catch { failure = "Couldn\u{2019}t save: \(error.localizedDescription)" }
        }
    }

    @ViewBuilder func row(_ p: SourcePreference) -> some View {
        switch p.kind {
        case .toggle(let on):
            SetRow(label: p.title, hint: p.summary.isEmpty ? nil : p.summary) {
                MonoSwitch(isOn: Binding(get: { on }, set: { var q = p; q.kind = .toggle($0); save(q) }))
            }
            .opacity(p.enabled ? 1 : 0.4).disabled(!p.enabled)
        case .text(let t):
            SetRow(label: p.title, hint: p.summary.isEmpty ? nil : p.summary) {
                MonoField(placeholder: "—", text: Binding(get: { drafts[p.position] ?? t }, set: { drafts[p.position] = $0 }), width: 170)
                    .onSubmit { if let d = drafts[p.position], d != t { var q = p; q.kind = .text(d); save(q) } }
            }
            .opacity(p.enabled ? 1 : 0.4).disabled(!p.enabled)
        case .list(let entries, let values, let cur):
            SetRow(label: p.title, hint: p.summary.isEmpty ? nil : p.summary) {
                if values.count <= 3 {
                    MonoChoice(options: values.indices.map { (values[$0], entries.indices.contains($0) ? entries[$0] : values[$0]) },
                               selection: Binding(get: { cur }, set: { var q = p; q.kind = .list(entries: entries, values: values, current: $0); save(q) }))
                } else {
                Menu {
                    ForEach(values.indices, id: \.self) { k in
                        Button {
                            var q = p; q.kind = .list(entries: entries, values: values, current: values[k]); save(q)
                        } label: {
                            let name = entries.indices.contains(k) ? entries[k] : values[k]
                            if values[k] == cur { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    let i = values.firstIndex(of: cur)
                    HStack(spacing: 6) {
                        Text(i.flatMap { entries.indices.contains($0) ? entries[$0] : nil } ?? cur).font(.system(size: 13.5, design: .monospaced)).lineLimit(1)
                        Text("▾").font(.system(size: 10))
                    }
                    .foregroundStyle(Theme.ink).padding(.horizontal, 9).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
            }
            .opacity(p.enabled ? 1 : 0.4).disabled(!p.enabled)
        case .multi(let entries, let values, let cur):
            VStack(alignment: .leading, spacing: 10) {
                Text(p.title).font(.folioBody).foregroundStyle(Theme.ink)
                if !p.summary.isEmpty { Text(p.summary).font(.folioMeta).foregroundStyle(Theme.faint) }
                FlowLayout(spacing: 6) {
                    ForEach(values.indices, id: \.self) { k in
                        let on = cur.contains(values[k])
                        Button {
                            var next = cur
                            if on { next.removeAll { $0 == values[k] } } else { next.append(values[k]) }
                            var q = p; q.kind = .multi(entries: entries, values: values, current: next); save(q)
                        } label: {
                            Text(entries.indices.contains(k) ? entries[k] : values[k]).font(.system(size: 13.5))
                                .foregroundStyle(on ? Theme.onInk : Theme.dim)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(on ? Theme.ink : Color.clear, in: Capsule())
                                .overlay { if !on { Capsule().strokeBorder(Theme.line) } }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            .opacity(p.enabled ? 1 : 0.4).disabled(!p.enabled)
        }
    }
}
