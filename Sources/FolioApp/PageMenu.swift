import AppKit
import FolioCore

/// Right-click / press-and-hold menu on a reader page: copy, save, share, use as the series cover.
@MainActor
enum PageMenu {
    private final class Item: NSMenuItem {
        var handler: (() -> Void)?
        @objc func fire() { handler?() }
    }

    private static func item(_ title: String, symbol: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let i = Item(title: title, action: #selector(Item.fire), keyEquivalent: "")
        i.target = i
        i.handler = handler
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return i
    }

    /// `view` anchors the share sheet; `at` is the point in it.
    static func make(page: PageRef, number: Int, model: ReaderModel, source: Source, view: NSView, at point: NSPoint,
                     cropToggle: Bool) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let head = NSMenuItem(title: "Page \(number)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        m.addItem(.separator())

        func bytes() async -> Data? { try? await source.imageData(page) }

        m.addItem(item("Copy page", symbol: "doc.on.doc") {
            Task {
                guard let d = await bytes(), let img = NSImage(data: d) else { return model.show(toast: "Couldn\u{2019}t copy this page") }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
                model.show(toast: "Copied page \(number)")
            }
        })
        m.addItem(item("Save page…", symbol: "square.and.arrow.down") {
            Task {
                guard let d = await bytes() else { return model.show(toast: "Couldn\u{2019}t save this page") }
                let ext = d.starts(with: [0x89, 0x50]) ? "png" : (d.starts(with: [0xff, 0xd8]) ? "jpg" : (d.starts(with: [0x47, 0x49]) ? "gif" : "webp"))
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(model.series.title) – \(model.chapter.name) – \(number).\(ext)"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { try d.write(to: url); model.show(toast: "Saved page \(number)") }
                catch { model.show(toast: "Couldn\u{2019}t save: \(error.localizedDescription)") }
            }
        })
        m.addItem(item("Share…", symbol: "square.and.arrow.up") { [weak view] in
            Task {
                guard let view, let d = await bytes(), let img = NSImage(data: d) else { return }
                NSSharingServicePicker(items: [img]).show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
            }
        })
        m.addItem(.separator())
        m.addItem(item("Use as cover", symbol: "photo") {
            Task {
                guard let d = await bytes(), let img = Images.decode(d, maxWidth: 600),
                      let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                    return model.show(toast: "Couldn\u{2019}t use this page")
                }
                model.app.library.setCover(model.series.id, jpeg: jpg)
                model.show(toast: "Cover updated")
            }
        })
        if cropToggle {
            m.addItem(.separator())
            let on = model.prefs.cropBorders
            let t = item(on ? "Show margins" : "Crop margins", symbol: "crop") {
                model.app.library.setReaderPref(model.series.id, \.cropBorders, \.cropBorders, !on)
            }
            m.addItem(t)
        }
        return m
    }
}
