import AppKit

// Draw at each iconset resolution so the Finder and Dock share a crisp mark.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 128, y: CGFloat(pixels) / 128)
        let tile = NSBezierPath(roundedRect: NSRect(x: 9, y: 9, width: 110, height: 110), xRadius: 25, yRadius: 25)
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.83, blue: 0.53, alpha: 1),
                   ending: NSColor(srgbRed: 0.95, green: 0.62, blue: 0.31, alpha: 1))!.draw(in: tile, angle: -55)
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: 21, y: 64))
        eye.curve(to: NSPoint(x: 107, y: 64), controlPoint1: NSPoint(x: 45, y: 100), controlPoint2: NSPoint(x: 83, y: 100))
        eye.curve(to: NSPoint(x: 21, y: 64), controlPoint1: NSPoint(x: 83, y: 28), controlPoint2: NSPoint(x: 45, y: 28))
        eye.close()
        eye.appendOval(in: NSRect(x: 47, y: 47, width: 34, height: 34))
        eye.windingRule = .evenOdd
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1).setFill()
        eye.fill()
        NSBezierPath(ovalIn: NSRect(x: 56, y: 56, width: 16, height: 16)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
