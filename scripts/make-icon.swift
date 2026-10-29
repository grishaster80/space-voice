// Draws the app icon: a mic over a space bar on a violet squircle.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [
        NSColor(red: 0.43, green: 0.30, blue: 0.98, alpha: 1),
        NSColor(red: 0.95, green: 0.33, blue: 0.55, alpha: 1),
    ])!.draw(in: shape, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: 380 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let m = mic.size
        mic.draw(in: NSRect(x: (size - m.width) / 2, y: 400 * s, width: m.width, height: m.height))
    }
    let bar = NSBezierPath(roundedRect: NSRect(x: 262 * s, y: 215 * s, width: 500 * s, height: 110 * s),
                           xRadius: 34 * s, yRadius: 34 * s)
    NSColor.white.withAlphaComponent(0.92).setFill()
    bar.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).write(to: output.appendingPathComponent(name))
    }
}
