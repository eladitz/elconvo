// Draws the app icon (an orange with a convert arrow) into an .iconset folder.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let body = NSRect(x: s * 0.1, y: s * 0.07, width: s * 0.8, height: s * 0.8)
    NSGradient(colors: [NSColor(red: 1, green: 0.72, blue: 0.25, alpha: 1), NSColor(red: 0.98, green: 0.42, blue: 0.05, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: body), angle: -60)
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: s * 0.5, y: s * 0.84))
    leaf.curve(to: NSPoint(x: s * 0.78, y: s * 0.95), controlPoint1: NSPoint(x: s * 0.55, y: s * 0.98), controlPoint2: NSPoint(x: s * 0.7, y: s * 1.0))
    leaf.curve(to: NSPoint(x: s * 0.5, y: s * 0.84), controlPoint1: NSPoint(x: s * 0.72, y: s * 0.86), controlPoint2: NSPoint(x: s * 0.6, y: s * 0.82))
    NSColor(red: 0.2, green: 0.62, blue: 0.3, alpha: 1).setFill()
    leaf.fill()
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: s * 0.36, weight: .bold).applying(.init(paletteColors: [.white]))) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
