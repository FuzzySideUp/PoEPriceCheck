import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import PoECore

enum TestData {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let gameData: GameData = try! GameData(directory: root.appendingPathComponent("Data/poe2"))
    static var parser: ItemParser { ItemParser(data: gameData) }
    static let poe1Data: GameData = try! GameData(directory: root.appendingPathComponent("Data/poe1"), game: .poe1)
    static var poe1Parser: ItemParser { ItemParser(data: poe1Data) }
    static func data(_ game: Game) -> GameData { game == .poe1 ? poe1Data : gameData }
    static var detector: GameDetector { GameDetector(data: [.poe1: poe1Data, .poe2: gameData]) }

    /// Text-only tooltip: "--------" lines separate blocks.
    static func lines(_ text: String, color: TextColor = .other) -> [OCRLine] {
        text.split(separator: "\n").map { OCRLine(text: String($0), color: color) }
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Renders PoE-style tooltips (dark box, centred coloured lines, separators) onto a busy background,
/// then round-trips through JPEG to mimic stream compression.
enum TooltipRenderer {
    struct Line { var text: String; var color: TextColor; var header = false }

    static func rgb(_ c: TextColor) -> CGColor {
        let r = c.reference.first ?? (220, 220, 220)
        return CGColor(red: r.0 / 255, green: r.1 / 255, blue: r.2 / 255, alpha: 1)
    }

    /// Blocks of lines; the first block is the header. Returns the image and the cursor position.
    static func render(_ blocks: [[Line]], canvas: CGSize = CGSize(width: 2400, height: 1600),
                       tooltipOrigin: CGPoint = CGPoint(x: 900, y: 250)) -> (CGImage, CGPoint) {
        let w = Int(canvas.width), h = Int(canvas.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Flip to top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)

        // Busy "game" background: gradient bands + random blobs + unrelated text.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<40 {
            ctx.setFillColor(CGColor(red: 0.2 + 0.3 * Double(i % 3) / 3, green: 0.25, blue: 0.15 + Double(i % 5) / 12, alpha: 1))
            ctx.fill(CGRect(x: 0, y: CGFloat(i) * canvas.height / 40, width: canvas.width, height: canvas.height / 40 + 1))
        }
        for _ in 0..<120 {
            let r = CGFloat.random(in: 10...90, using: &rng)
            ctx.setFillColor(CGColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 0.6))
            ctx.fillEllipse(in: CGRect(x: .random(in: 0...canvas.width), y: .random(in: 0...canvas.height), width: r, height: r))
        }
        draw("Waypoint", at: CGPoint(x: 200, y: 1300), size: 30, color: rgb(.white), in: ctx, centeredOn: nil)
        draw("[Global] someone: wts mirror", at: CGPoint(x: 40, y: 1500), size: 26, color: rgb(.white), in: ctx, centeredOn: nil)

        // Measure tooltip.
        let bodySize: CGFloat = 30, headerSize: CGFloat = 38
        let lineGap: CGFloat = 10, sepGap: CGFloat = 34
        var width: CGFloat = 0
        var height: CGFloat = 30
        for (bi, block) in blocks.enumerated() {
            for l in block {
                let size = bi == 0 ? headerSize : bodySize
                width = max(width, textWidth(l.text, size: size))
                height += size + lineGap
            }
            height += sepGap
        }
        width += 120
        let box = CGRect(origin: tooltipOrigin, size: CGSize(width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.03, green: 0.025, blue: 0.02, alpha: 0.93))
        ctx.fill(box)
        ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1)); ctx.setLineWidth(2); ctx.stroke(box)

        var y = box.minY + 20
        for (bi, block) in blocks.enumerated() {
            if bi == 0 {
                let hh = CGFloat(block.count) * (headerSize + lineGap) + 16
                ctx.setFillColor(CGColor(red: 0.10, green: 0.075, blue: 0.04, alpha: 1))  // real headers measure 13-32 brightness
                ctx.fill(CGRect(x: box.minX + 4, y: y - 8, width: box.width - 8, height: hh))
            }
            for l in block {
                let size = bi == 0 ? headerSize : bodySize
                draw(l.text, at: CGPoint(x: 0, y: y), size: size, color: rgb(l.color), in: ctx, centeredOn: box.midX)
                y += size + lineGap
            }
            y += sepGap / 2
            if bi < blocks.count - 1 {
                ctx.setStrokeColor(CGColor(red: 0.5, green: 0.4, blue: 0.25, alpha: 1)); ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: box.midX - box.width * 0.35, y: y - 6)); ctx.addLine(to: CGPoint(x: box.midX + box.width * 0.35, y: y - 6))
                ctx.strokePath()
            }
            y += sepGap / 2
        }

        let raw = ctx.makeImage()!
        let cursor = CGPoint(x: box.minX - 30, y: box.maxY - 40)
        return (jpegRoundTrip(raw), cursor)
    }

    static func font(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Georgia" as CFString, size, nil) }

    static func textWidth(_ s: String, size: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font(size)]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    static func draw(_ s: String, at p: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext, centeredOn cx: CGFloat?) {
        let attr = NSAttributedString(string: s, attributes: [.font: font(size), .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x = cx.map { $0 - w / 2 } ?? p.x
        ctx.saveGState()
        // Undo the flip locally so glyphs are upright.
        ctx.translateBy(x: x, y: p.y + size); ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func jpegRoundTrip(_ image: CGImage) -> CGImage {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(data, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }
}
