import AppKit
import SwiftUI

enum Brand {
    static let orange = Color(red: 241 / 255, green: 84 / 255, blue: 54 / 255)

    static func featherPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 20.6, y: 3.4))
        p.addCurve(to: CGPoint(x: 11.5, y: 4.8), control1: CGPoint(x: 18.2, y: 1), control2: CGPoint(x: 14.2, y: 2))
        p.addCurve(to: CGPoint(x: 8.7, y: 13.1), control1: CGPoint(x: 8.8, y: 7.5), control2: CGPoint(x: 8, y: 10.5))
        p.addLine(to: CGPoint(x: 4, y: 17.8))
        p.addLine(to: CGPoint(x: 2.5, y: 21.8))
        p.addLine(to: CGPoint(x: 6.5, y: 20.3))
        p.addLine(to: CGPoint(x: 11.2, y: 15.6))
        p.addCurve(to: CGPoint(x: 19.5, y: 12.8), control1: CGPoint(x: 13.8, y: 16.3), control2: CGPoint(x: 16.8, y: 15.5))
        p.addCurve(to: CGPoint(x: 20.6, y: 3.4), control1: CGPoint(x: 22.2, y: 10.1), control2: CGPoint(x: 23, y: 5.8))
        p.closeSubpath()
        return p
    }

    static func drawFeather(in ctx: CGContext, rect: CGRect, color: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 24, y: rect.height / 24)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(featherPath())
        ctx.setFillColor(color)
        ctx.fillPath()
        // Cut the shaft and branches out so the menu template works on any backdrop.
        ctx.setBlendMode(.destinationOut)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1.1)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 5, y: 19))
        ctx.addLine(to: CGPoint(x: 17, y: 7))
        ctx.move(to: CGPoint(x: 10, y: 14))
        ctx.addLine(to: CGPoint(x: 16, y: 14.1))
        ctx.move(to: CGPoint(x: 14, y: 10))
        ctx.addLine(to: CGPoint(x: 14, y: 6))
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func menuImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawFeather(in: ctx, rect: rect, color: CGColor(gray: 0, alpha: 1))
            return true
        }
        image.isTemplate = true
        return image
    }
}

// One factor sizes the whole interface; the preference offers 标准 / 大 / 特大.
enum Scale {
    static let choices: [Double] = [1.0, 1.2, 1.4]
    static var value: CGFloat = 1.2
}
func u(_ points: CGFloat) -> CGFloat { (points * Scale.value).rounded() }

// Palette and type follow nexastore.cn: paper and ink neutrals, one accent, Manrope for display text.
extension Brand {
    static func nsColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
    static let paperColor = nsColor(0xFAFAFA, 0x1B1B19)
    static let paper = Color(nsColor: paperColor)
    static let surface = Color(nsColor: nsColor(0xF0F0ED, 0x2A2A26))
    static let ink = Color(nsColor: nsColor(0x171715, 0xF8F8F2))
    static let body = Color(nsColor: nsColor(0x484845, 0xD1D1C9))
    static let muted = Color(nsColor: nsColor(0x666662, 0xB0B0A7))
    static let line = Color(nsColor: nsColor(0xDDDDDA, 0x41413B))
    static let accent = Color(nsColor: nsColor(0xF15436, 0xFF795D))
    static let accentSoft = Color(nsColor: nsColor(0xFFF0EB, 0x392822))
    static let onInk = Color(nsColor: nsColor(0xFFFFFF, 0x1B1B19))
    static let caution = Color(nsColor: nsColor(0xD9730D, 0xF0A04B))
    static let danger = Color(nsColor: nsColor(0xD92D20, 0xFF6B5E))
    static let good = Color(nsColor: nsColor(0x1F9D6B, 0x4CC38A))

    // The product card on the site: charcoal in both themes, with its own light text.
    static let card = Color(nsColor: nsColor(0x282927, 0x31312C))
    static let cardText = Color(red: 243 / 255, green: 242 / 255, blue: 239 / 255)
    static let cardMuted = Color(red: 222 / 255, green: 221 / 255, blue: 216 / 255).opacity(0.62)

    enum Weight: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold", heavy = "ExtraBold" }
    // Named instances of the site's variable Manrope. Figures are medium, as prices are on the site.
    static func display(_ size: CGFloat, _ weight: Weight = .medium) -> Font {
        .custom("Manrope-\(weight.rawValue)", fixedSize: size * Scale.value)
    }

    // Fine monochrome noise, tiled over the card for its frosted texture. Seeded so every launch matches.
    static let grain: NSImage = {
        let side = 96
        var seed: UInt64 = 0x6E657861
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0..<(side * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8(truncatingIfNeeded: seed >> 56)
            pixels[index * 4] = value; pixels[index * 4 + 1] = value; pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = 255
        }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        if let provider = CGDataProvider(data: Data(pixels) as CFData),
           let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        }
        return image
    }()
}

// Small spaced caption, as in "NEXA · 使用提醒" on the site.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Brand.display(9, .bold)).tracking(1.3).foregroundStyle(Brand.muted).lineLimit(1)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Brand.line).frame(height: 1) }
}

// The site's call to action: an ink button joined to an accent square carrying the arrow.
struct SplitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            configuration.label.font(.system(size: u(11), weight: .medium)).foregroundStyle(Brand.onInk)
                .padding(.horizontal, u(13)).frame(height: u(30)).background(Brand.ink)
            Image(systemName: "arrow.up.right").font(.system(size: u(9), weight: .bold))
                .foregroundStyle(Color(red: 23 / 255, green: 23 / 255, blue: 21 / 255))
                .frame(width: u(30), height: u(30)).background(Brand.accent)
        }
        .clipShape(RoundedRectangle(cornerRadius: u(3), style: .continuous))
        .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

// The outlined round arrow on each product tile.
struct RoundArrow: View {
    var body: some View {
        Image(systemName: "arrow.up.right").font(.system(size: u(8), weight: .bold)).foregroundStyle(Brand.ink)
            .frame(width: u(22), height: u(22)).overlay(Circle().stroke(Brand.line, lineWidth: 1))
    }
}

// The accent tag in the corner of a product card ("Plus", "Pro 100").
struct AccentTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.display(9, .semibold)).foregroundStyle(Color(red: 23 / 255, green: 23 / 255, blue: 21 / 255))
            .padding(.horizontal, u(6)).padding(.vertical, u(3))
            .background(Brand.accent, in: RoundedRectangle(cornerRadius: u(3), style: .continuous))
    }
}

struct FeatherView: View {
    var body: some View {
        Image(nsImage: Brand.menuImage(size: 24)).renderingMode(.template).resizable()
            .aspectRatio(contentMode: .fit).accessibilityHidden(true)
    }
}
