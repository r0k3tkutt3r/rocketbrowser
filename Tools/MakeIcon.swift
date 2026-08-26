import Cocoa

// Writes the PNGs of a macOS .iconset directory; build.sh feeds the result to iconutil.
// Compiled together with Tools/AppIcon.swift, so the icon has exactly one definition.
@main
enum MakeIcon {

    /// (points, scale) pairs iconutil expects for a complete icns.
    static let variants: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
        (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    static func main() throws {
        // Touch the shared NSApplication so AppKit text/emoji rendering is fully
        // initialized in this headless tool.
        _ = NSApplication.shared

        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: MakeIcon <output.iconset>\n".utf8))
            exit(2)
        }
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for variant in variants {
            let pixels = variant.points * variant.scale
            guard let data = AppIcon.pngData(pixels: pixels) else {
                FileHandle.standardError.write(Data("failed to render \(pixels)px icon\n".utf8))
                exit(1)
            }
            let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
            try data.write(to: outputDirectory.appendingPathComponent(
                "icon_\(variant.points)x\(variant.points)\(suffix).png"))
        }
        print("wrote \(variants.count) icon sizes to \(outputDirectory.path)")
    }
}
