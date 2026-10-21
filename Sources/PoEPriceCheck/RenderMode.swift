import AppKit
import ImageIO
import PoECore
import SwiftUI
import UniformTypeIdentifiers

/// `PoEPriceCheck --render-panel <tooltip.png|jpg> <out.png> [cursorX cursorY]`
/// Runs a saved screenshot through the real OCR + pricing pipeline and writes the tooltip and the
/// result panel side by side (used for README screenshots; the live panel is excluded from captures).
extension PriceCheckController {
    func renderPanel(input: String, output: String, cursor: CGPoint?) async {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read \(input)"); return }
        do {
            let read = try TooltipReader.read(image: image, cursor: cursor)
            let item = parse(read, windowTitle: nil)
            model.reset()
            model.zoom = 1.25
            model.item = item
            let league = try await league()
            model.league = league
            try await renderPrice(item, league: league)
            // Wait for the trade search to finish.
            for _ in 0..<200 where model.searching { try await Task.sleep(nanoseconds: 100_000_000) }
            try await Task.sleep(nanoseconds: 300_000_000)

            let host = NSHostingView(rootView: PanelView(model: model))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let panel = rep.cgImage else { return }

            let tip = read.tooltipRect.insetBy(dx: -24, dy: -24).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let tooltip = image.cropping(to: tip) else { return }
            let gap = 48, pad = 32
            let w = pad + tooltip.width + gap + panel.width + pad
            let h = pad * 2 + max(tooltip.height, panel.height)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(tooltip, in: CGRect(x: pad, y: h - pad - tooltip.height, width: tooltip.width, height: tooltip.height))
            ctx.draw(panel, in: CGRect(x: pad + tooltip.width + gap, y: h - pad - panel.height, width: panel.width, height: panel.height))
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            print("wrote \(output) (\(item.rarity) \(item.name ?? "-"))")
        } catch {
            print("render failed: \(error)")
        }
    }
}
