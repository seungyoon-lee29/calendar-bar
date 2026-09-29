// Draws the app icon (paper calendar: blue header band, dot grid, today circle, event dot)
// into an .iconset directory. Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}

// Shadows ignore the transform, so they take the pixel scale explicitly.
// Coordinates use a 1024-point canvas with the origin at the top-left.
func draw(scale k: CGFloat) {
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12 * k)
    shadow.shadowBlurRadius = 28 * k
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.set()
    color(0xFFFFFF).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(starting: color(0xFFFFFF), ending: color(0xEEF1F6))!.draw(in: body, angle: -45)
    color(0x3B6EF5).setFill()
    NSRect(x: 100, y: 100, width: 824, height: 190).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x000000, 0.08).setStroke()
    body.lineWidth = 4
    body.stroke()

    let columns: [CGFloat] = [232, 370, 512, 654, 792], rows: [CGFloat] = [395, 515, 635, 755]
    for (r, y) in rows.enumerated() {
        for (c, x) in columns.enumerated() where !(c == 2 && (r == 1 || r == 2)) {
            circle(x, y, 15, color(0xC3CAD7))
        }
    }
    circle(512, 515, 58, color(0x3B6EF5))
    circle(512, 619, 22, color(0xFF5A4E))
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: CGFloat(pixels))
        transform.scaleX(by: CGFloat(pixels) / 1024, yBy: -CGFloat(pixels) / 1024)
        transform.concat()
        draw(scale: CGFloat(pixels) / 1024)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
