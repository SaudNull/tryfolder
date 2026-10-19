import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let set = root.appendingPathComponent("TryFolder.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let background = NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948), xRadius: 218, yRadius: 218)
        NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.55, blue: 0.97, alpha: 1), ending: NSColor(srgbRed: 0.03, green: 0.30, blue: 0.77, alpha: 1))!.draw(in: background, angle: -90)
        let back = NSBezierPath(roundedRect: NSRect(x: 195, y: 330, width: 620, height: 410), xRadius: 56, yRadius: 56)
        NSColor.white.withAlphaComponent(0.36).setFill(); back.fill()
        let tab = NSBezierPath(roundedRect: NSRect(x: 195, y: 635, width: 265, height: 142), xRadius: 39, yRadius: 39)
        NSColor.white.withAlphaComponent(0.36).setFill(); tab.fill()
        let front = NSBezierPath(roundedRect: NSRect(x: 177, y: 244, width: 670, height: 420), xRadius: 60, yRadius: 60)
        NSGradient(starting: NSColor.white, ending: NSColor(srgbRed: 0.78, green: 0.93, blue: 1, alpha: 1))!.draw(in: front, angle: -90)
        let check = NSBezierPath(); check.move(to: NSPoint(x: 384, y: 448)); check.line(to: NSPoint(x: 477, y: 360)); check.line(to: NSPoint(x: 643, y: 550)); check.lineWidth = 55; check.lineCapStyle = .round; check.lineJoinStyle = .round
        NSColor(srgbRed: 0.05, green: 0.42, blue: 0.89, alpha: 1).setStroke(); check.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)); NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
