import CoreGraphics
import Foundation

/// Finds the plain white/black margins around a scanned page so the reader can zoom them away.
public enum BorderCrop {
    /// The content area as a fraction of the image, origin top-left. `nil` when there is nothing worth cropping.
    public static func content(of image: CGImage) -> CGRect? {
        let scale = min(1, 240.0 / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale)), h = max(8, Int(Double(image.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        // A line is margin when it is one flat near-white or near-black colour.
        func blank(_ values: [UInt8]) -> Bool {
            guard let lo = values.min(), let hi = values.max() else { return true }
            return hi &- lo <= 14 && (hi >= 232 || hi <= 24)
        }
        func row(_ y: Int) -> [UInt8] { Array(px[(y * w)..<((y + 1) * w)]) }
        func col(_ x: Int) -> [UInt8] { (0..<h).map { px[$0 * w + x] } }

        let maxY = Int(Double(h) * 0.3), maxX = Int(Double(w) * 0.3)
        var top = 0, bottom = 0, left = 0, right = 0
        while top < maxY, blank(row(top)) { top += 1 }
        while bottom < maxY, blank(row(h - 1 - bottom)) { bottom += 1 }
        while left < maxX, blank(col(left)) { left += 1 }
        while right < maxX, blank(col(w - 1 - right)) { right += 1 }
        if top >= maxY && bottom >= maxY && left >= maxX && right >= maxX { return nil }     // an empty page: nothing to frame
        // Leave a hair of margin so art that touches the edge isn't shaved.
        top = max(0, top - 1); bottom = max(0, bottom - 1); left = max(0, left - 1); right = max(0, right - 1)

        let r = CGRect(x: Double(left) / Double(w), y: Double(top) / Double(h),
                       width: Double(w - left - right) / Double(w), height: Double(h - top - bottom) / Double(h))
        return r.width * r.height > 0.97 ? nil : r          // under 3% saved: not worth it
    }
}
