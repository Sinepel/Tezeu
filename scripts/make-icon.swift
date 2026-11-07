// Fabrique Resources/AppIcon.icns à partir de Resources/AppIcon.svg, avec le moteur SVG de macOS.
// Usage : swift scripts/make-icon.swift   (puis le .icns est intégré par build.sh)
import AppKit

let root = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let svg = root.appending(path: "Resources/AppIcon.svg")
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
let output = root.appending(path: "Resources/AppIcon.icns")

guard let image = NSImage(contentsOf: svg) else { fatalError("SVG illisible : \(svg.path)") }
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try png(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
try png(1024).write(to: root.appending(path: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "OK : \(output.path)" : "iconutil a échoué")
