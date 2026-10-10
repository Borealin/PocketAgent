import AppKit
import Foundation

// Original vector drawing; no external artwork or user screenshots.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.31, green: 0.25, blue: 0.77, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 178, y: 260, width: 668, height: 536), xRadius: 142, yRadius: 142).fill()
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 254, y: 304))
tail.line(to: NSPoint(x: 238, y: 172))
tail.line(to: NSPoint(x: 417, y: 285))
tail.close()
tail.fill()
NSColor(calibratedRed: 0.31, green: 0.25, blue: 0.77, alpha: 1).setFill()
for x in [340.0, 512.0, 684.0] {
    NSBezierPath(ovalIn: NSRect(x: x - 44, y: 486, width: 88, height: 88)).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
