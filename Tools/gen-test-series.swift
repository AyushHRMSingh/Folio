// Generates a fake series of tall webtoon-style strips (3 chapters x 8 pages) for testing.
// usage: gen-test-series <local-library-folder> [series name] [hue shift]
import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Strip Test"
let hueShift = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 0
let heights = [2400, 3100, 1800, 3600, 2200, 2900, 2000, 3300]
for ch in 1...3 {
  for (i, h) in heights.enumerated() {
    let w = 800
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let hue = CGFloat((ch * 8 + i + hueShift) % 24) / 24
    NSGradient(starting: NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1), ending: NSColor(hue: hue, saturation: 0.6, brightness: 0.55, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 90), .foregroundColor: NSColor.white]
    for y in stride(from: 150, to: h, by: 700) { ("C\(ch) P\(i + 1)" as NSString).draw(at: NSPoint(x: 220, y: h - y), withAttributes: attrs) }
    NSColor.white.withAlphaComponent(0.5).setFill(); NSRect(x: 0, y: 0, width: w, height: 6).fill(); NSRect(x: 0, y: h - 6, width: w, height: 6).fill()
    NSGraphicsContext.restoreGraphicsState()
    let dir = root.appendingPathComponent("\(name)/Chapter \(ch)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: dir.appendingPathComponent(String(format: "%02d.jpg", i + 1)))
  }
}
try! FileManager.default.copyItem(at: root.appendingPathComponent("\(name)/Chapter 1/01.jpg"), to: root.appendingPathComponent("\(name)/cover.jpg"))
