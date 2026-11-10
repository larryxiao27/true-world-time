import AppKit
import Foundation

// Reproducible vector geometry, rasterized only at build time.
// Two slightly offset paths share a clock: a personal place within passing time.
func makeIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let compact = size <= 32
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.21, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.105, green: 0.170, blue: 0.215, alpha: 1),
               ending: NSColor(calibratedRed: 0.185, green: 0.290, blue: 0.345, alpha: 1))!
        .draw(in: background, angle: 90)

    let orbit = NSBezierPath()
    orbit.appendArc(withCenter: NSPoint(x: 456, y: 550), radius: 278, startAngle: 96, endAngle: 305)
    orbit.lineWidth = compact ? 36 : 30
    orbit.lineCapStyle = .round
    NSColor(calibratedRed: 0.43, green: 0.56, blue: 0.60, alpha: 1).setStroke()
    orbit.stroke()

    let center = NSPoint(x: 544, y: 484)
    let face = NSBezierPath(ovalIn: NSRect(x: center.x - 255, y: center.y - 255, width: 510, height: 510))
    NSColor(calibratedRed: 0.135, green: 0.220, blue: 0.270, alpha: 1).setFill()
    face.fill()
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: 255, startAngle: 72, endAngle: 378)
    ring.lineWidth = compact ? 46 : 38
    ring.lineCapStyle = .round
    let ivory = NSColor(calibratedRed: 0.955, green: 0.945, blue: 0.905, alpha: 1)
    ivory.setStroke()
    ring.stroke()

    let hands = NSBezierPath()
    hands.move(to: NSPoint(x: 441, y: 557))
    hands.line(to: center)
    hands.line(to: NSPoint(x: 700, y: 574))
    hands.lineWidth = compact ? 54 : 48
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.stroke()

    let point = NSPoint(x: center.x + 255 / sqrt(2), y: center.y + 255 / sqrt(2))
    NSColor(calibratedRed: 0.965, green: 0.705, blue: 0.425, alpha: 1).setFill()
    let radius: CGFloat = compact ? 35 : 31
    NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("evidence/MyTimeZone.iconset", isDirectory: true)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let image = makeIcon(size: size * scale)
        let data = image.representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
for size in [32, 256, 1024] {
    try makeIcon(size: size).representation(using: .png, properties: [:])!
        .write(to: assets.appendingPathComponent("my-time-zone-\(size).png"))
}
print(iconset.path)
