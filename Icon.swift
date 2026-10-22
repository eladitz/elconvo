// Draws the app icon into an .iconset folder: the drag wheel itself, on an indigo tile, with one
// petal lit the way it lights up under the pointer and the convert arrows in the hub.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// An annular sector between angles a0...a1 (radians, 0 = up, clockwise) with a gap between neighbours.
func petal(centre c: CGPoint, inner: CGFloat, outer: CGFloat, a0: CGFloat, a1: CGFloat, gap: CGFloat) -> NSBezierPath {
    func at(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * sin(a), y: c.y + r * cos(a)) }
    let po = gap / 2 / outer, pi = gap / 2 / inner
    let path = NSBezierPath()
    let steps = 24
    path.move(to: at(outer, a0 + po))
    for i in 1...steps { path.line(to: at(outer, a0 + po + (a1 - a0 - 2 * po) * CGFloat(i) / CGFloat(steps))) }
    for i in 0...steps { path.line(to: at(inner, a1 - pi - (a1 - a0 - 2 * pi) * CGFloat(i) / CGFloat(steps))) }
    path.close()
    path.lineJoinStyle = .round
    return path
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Tile: the standard macOS icon grid leaves ~10% margin around a rounded square.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(0x2A1E66).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x7B6CFF), color(0x4B3BD6), color(0x23185E)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(in: tilePath, angle: -70)
    // A soft sheen across the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: tile.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: s * 0.176, yRadius: s * 0.176), angle: -90)

    // The wheel.
    let c = CGPoint(x: s / 2, y: s / 2)
    let outer = s * 0.30, inner = s * 0.135
    let count = 8
    let span = 2 * CGFloat.pi / CGFloat(count)
    let round = max(1, s * 0.022)   // stroke width that rounds the petal corners
    for i in 0..<count {
        let a0 = CGFloat(i) * span - span / 2
        let p = petal(centre: c, inner: inner + round / 2, outer: outer - round / 2, a0: a0, a1: a0 + span, gap: s * 0.042)
        p.lineWidth = round
        if i == 1 {
            // The lit petal, nudged outward the way a hovered petal grows.
            let lit = petal(centre: c, inner: inner + round / 2, outer: outer + s * 0.02 - round / 2, a0: a0, a1: a0 + span, gap: s * 0.042)
            lit.lineWidth = round
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = color(0xFF7A2E, 0.6)
            glow.shadowBlurRadius = s * 0.03
            glow.set()
            color(0xFF7A2E).setFill(); color(0xFF7A2E).setStroke()
            lit.fill(); lit.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(colors: [color(0xFFA14A), color(0xF2552C)])!.draw(in: lit, angle: -90)
            color(0xFF8A3D).setStroke(); lit.stroke()
        } else {
            color(0xEDEBFF, 0.94).setFill(); color(0xEDEBFF, 0.94).setStroke()
            // Fill and stroke as one layer so the translucent edges don't double up.
            NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor(white: 1, alpha: 1).setFill(); NSColor(white: 1, alpha: 1).setStroke()
            p.fill(); p.stroke()
            NSGraphicsContext.current?.cgContext.endTransparencyLayer()
        }
    }

    // Hub with the convert arrows.
    let hubR = inner - s * 0.025
    let hub = NSBezierPath(ovalIn: NSRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2))
    color(0x1C1350).setFill()
    hub.fill()
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: hubR * 1.3, weight: .heavy).applying(.init(paletteColors: [.white]))) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
