import AppKit

@main
enum IconMaker {
    static func image(pixels: Int) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        ctx.translateBy(x: 0, y: 1024)
        ctx.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: rect, cornerWidth: 184, cornerHeight: 184, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 23, color: CGColor(gray: 0, alpha: 0.22))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0.075, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(gray: 0.19, alpha: 1), CGColor(gray: 0.055, alpha: 1)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 100), end: CGPoint(x: 870, y: 924), options: [])
        ctx.restoreGState()
        let rim = CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 182.5, cornerHeight: 182.5, transform: nil)
        ctx.addPath(rim)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.setLineWidth(3)
        ctx.strokePath()
        Brand.drawFeather(in: ctx, rect: CGRect(x: 225, y: 213, width: 574, height: 574),
                          color: CGColor(gray: 0.97, alpha: 1))
        ctx.flush()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = root.appendingPathComponent("Nexa.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try image(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try image(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try image(pixels: 1024).write(to: root.appendingPathComponent("nexa-icon.png"))
    }
}
