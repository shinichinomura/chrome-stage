import AppKit

// Chrome のロゴを使わず、重なるウィンドウと切り替えパレットを描く。
// 依存ライブラリなしで同じ AppIcon を再生成できる。
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "app/ChromeStage/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()

    let background = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                                  xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x102A56, alpha: 0.22)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x2458C5).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x1949B8), ending: color(0x5BA9F4))!
        .draw(in: background, angle: 65)

    rounded(NSRect(x: 330, y: 454, width: 510, height: 326), radius: 42,
            fill: color(0xC8E4FF, alpha: 0.55))
    rounded(NSRect(x: 260, y: 372, width: 510, height: 326), radius: 42,
            fill: color(0xE6F3FF, alpha: 0.8))

    NSGraphicsContext.saveGraphicsState()
    let windowShadow = NSShadow()
    windowShadow.shadowColor = color(0x102C66, alpha: 0.28)
    windowShadow.shadowBlurRadius = 30
    windowShadow.shadowOffset = NSSize(width: 0, height: -12)
    windowShadow.set()
    rounded(NSRect(x: 190, y: 290, width: 510, height: 326), radius: 42, fill: .white)
    NSGraphicsContext.restoreGraphicsState()

    for x in [230, 262, 294] {
        color(0x7198C7).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: 568, width: 16, height: 16)).fill()
    }
    rounded(NSRect(x: 222, y: 322, width: 446, height: 212), radius: 20, fill: color(0xE8F1FC))
    rounded(NSRect(x: 250, y: 440, width: 170, height: 22), radius: 11, fill: color(0x588ED5))
    rounded(NSRect(x: 250, y: 396, width: 306, height: 16), radius: 8, fill: color(0xADC7E9))

    NSGraphicsContext.saveGraphicsState()
    windowShadow.set()
    rounded(NSRect(x: 350, y: 214, width: 452, height: 98), radius: 36, fill: color(0xF4F9FF))
    NSGraphicsContext.restoreGraphicsState()
    for index in 0..<3 {
        rounded(NSRect(x: 372 + index * 138, y: 234, width: 128, height: 58), radius: 20,
                fill: color(index == 0 ? 0x147D91 : 0xDFEAF6))
    }
    color(0xC6FFF1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 424, y: 251, width: 24, height: 24)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try drawIcon(pixels: size * scale).write(to: destination.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)",
                       "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"))
print("AppIcon を生成: \(destination.path)")
