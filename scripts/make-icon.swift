import AppKit

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = NSRect(x: 82, y: 82, width: 860, height: 860)
        let path = NSBezierPath(roundedRect: rect, xRadius: 195, yRadius: 195)
        let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.shadowBlurRadius = 35; shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor(calibratedRed: 0.26, green: 0.28, blue: 0.78, alpha: 1).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedRed: 0.43, green: 0.49, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.73, alpha: 1))!.draw(in: path, angle: -70)
        NSColor.white.withAlphaComponent(0.14).setStroke(); path.lineWidth = 3; path.stroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 251, y: 251, width: 522, height: 522))
        NSColor.white.withAlphaComponent(0.94).setStroke(); ring.lineWidth = 33; ring.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 374, y: 374, width: 276, height: 276)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size)\(suffix).png"))
    }
}
