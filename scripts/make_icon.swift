// Draws Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
// The glyph is drawn from paths, not SF Symbols, which may not be used in app icons.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SecondWind-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt body centred on a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    color(0x141414).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x2A2A2A), color(0x151515)])!.draw(in: body, angle: -90)
    // A low teal glow rising from the bottom edge: the second wind arriving.
    NSGradient(colors: [color(0x3FD9C3, 0.32), color(0x3FD9C3, 0)])!
        .draw(in: NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.55), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFFFFF, 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 184 * s, yRadius: 184 * s)
    rim.lineWidth = 3 * s
    rim.stroke()

    // Three wind strokes, each ending in a curl, stacked with decreasing length.
    func gust(y: CGFloat, startX: CGFloat, endX: CGFloat, curl: CGFloat, up: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 58 * s
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let dir: CGFloat = up ? 1 : -1
        path.move(to: NSPoint(x: startX * s, y: y * s))
        path.line(to: NSPoint(x: endX * s, y: y * s))
        path.curve(
            to: NSPoint(x: (endX + curl) * s, y: (y + dir * curl) * s),
            controlPoint1: NSPoint(x: (endX + curl * 0.56) * s, y: y * s),
            controlPoint2: NSPoint(x: (endX + curl) * s, y: (y + dir * curl * 0.44) * s)
        )
        path.curve(
            to: NSPoint(x: endX * s, y: (y + dir * curl * 2) * s),
            controlPoint1: NSPoint(x: (endX + curl) * s, y: (y + dir * curl * 1.56) * s),
            controlPoint2: NSPoint(x: (endX + curl * 0.56) * s, y: (y + dir * curl * 2) * s)
        )
        path.curve(
            to: NSPoint(x: (endX - curl * 0.62) * s, y: (y + dir * curl * 1.4) * s),
            controlPoint1: NSPoint(x: (endX - curl * 0.36) * s, y: (y + dir * curl * 2) * s),
            controlPoint2: NSPoint(x: (endX - curl * 0.62) * s, y: (y + dir * curl * 1.75) * s)
        )
        return path
    }

    let teal = color(0x3FD9C3)
    let strokes = [
        (gust(y: 604, startX: 262, endX: 640, curl: 72, up: true), teal),
        (gust(y: 488, startX: 262, endX: 742, curl: 0, up: true), teal.withAlphaComponent(0.88)),
        (gust(y: 372, startX: 262, endX: 560, curl: 72, up: false), teal.withAlphaComponent(0.72)),
    ]
    for (path, tint) in strokes {
        tint.setStroke()
        path.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let png = drawIcon(size: pixels).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let preview = drawIcon(size: 1024).representation(using: .png, properties: [:])!
try preview.write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
