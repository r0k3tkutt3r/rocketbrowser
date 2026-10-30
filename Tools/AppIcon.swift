import Cocoa

/// The Rocket app icon, drawn in code at any size — the repo ships no image assets.
/// `build.sh` renders these into `Contents/Resources/Rocket.icns` via `Tools/MakeIcon.swift`,
/// which is what Finder, Launchpad, ⌘-Tab and the Dock actually read.
enum AppIcon {

    /// Apple's macOS icon grid: on a 1024pt canvas the rounded square is 824pt with a
    /// 185.4pt corner radius. Keeping these ratios makes Rocket sit at the same visual
    /// size as system icons instead of looking oversized next to them.
    private static let contentInsetRatio: CGFloat = 100.0 / 1024.0
    private static let cornerRadiusRatio: CGFloat = 185.4 / 1024.0
    private static let glyphSizeRatio: CGFloat = 0.52

    /// `fullBleed` is the iOS shape: iOS masks the icon itself and wants the whole
    /// square filled, where a macOS icon draws its own rounded body inside the grid.
    static func draw(in rect: NSRect, fullBleed: Bool = false) {
        let side = min(rect.width, rect.height)
        let square = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let inset = fullBleed ? 0 : side * contentInsetRatio
        let body = square.insetBy(dx: inset, dy: inset)
        let radius = fullBleed ? 0 : side * cornerRadiusRatio
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGradient(colors: [
            NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.65, alpha: 1),
            NSColor(calibratedRed: 0.63, green: 0.27, blue: 0.90, alpha: 1),
        ])?.draw(in: path, angle: 90)

        let glyph = NSAttributedString(
            string: "🚀",
            // Sized against the body, so the rocket fills both shapes alike.
            attributes: [.font: NSFont.systemFont(
                ofSize: body.width * glyphSizeRatio / (1 - 2 * contentInsetRatio))])
        let glyphSize = glyph.size()
        glyph.draw(at: NSPoint(x: square.midX - glyphSize.width / 2,
                               y: square.midY - glyphSize.height / 2))
    }

    /// Renders one square PNG at an exact pixel size, for the .iconset build step.
    static func pngData(pixels: Int, fullBleed: Bool = false) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)), fullBleed: fullBleed)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
