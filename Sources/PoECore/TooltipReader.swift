import CoreGraphics
import Foundation
import Vision

/// Finds the item tooltip in a screen capture and OCRs it.
///
/// PoE 2 tooltips are centre-aligned, so the tooltip is found as the tallest stack of OCR lines that
/// share a horizontal centre, preferring stacks near the cursor and ones containing tooltip keywords.
public enum TooltipReader {
    public struct Result: Sendable {
        public var lines: [OCRLine]          // tooltip lines, top to bottom
        public var tooltipRect: CGRect       // in image pixels
        public var allLines: [OCRLine]       // every OCR line in the capture
        public var ocrSeconds: Double
    }

    public static func read(image: CGImage, cursor: CGPoint?) throws -> Result {
        let t0 = Date()
        let pixels = PixelBuffer(image: image)
        let all = try recognize(image).map { line -> OCRLine in
            var l = line
            l.color = pixels?.textColor(in: l.rect) ?? .other
            l.background = pixels?.backgroundLevel(in: l.rect)
            return l
        }
        let ocr = Date().timeIntervalSince(t0)
        let tooltip = locateTooltip(all, cursor: cursor)
        let rect = tooltip.reduce(CGRect.null) { $0.union($1.rect) }
        return Result(lines: tooltip, tooltipRect: rect, allLines: all, ocrSeconds: ocr)
    }

    /// "Forbidden Rites League" in the area overlay -> "Forbidden Rites" (matched against known leagues).
    public static func detectLeague(in lines: [OCRLine], known: [String]) -> String? {
        for l in lines {
            let t = TextUtil.clean(l.text)
            guard t.lowercased().hasSuffix(" league") else { continue }
            let name = TextUtil.normalize(String(t.dropLast(7)))
            if let hit = known.first(where: { TextUtil.normalize($0) == name }) { return hit }
            if let hit = known.max(by: { TextUtil.similarity(TextUtil.normalize($0), name) < TextUtil.similarity(TextUtil.normalize($1), name) }),
               TextUtil.similarity(TextUtil.normalize(hit), name) > 0.85 { return hit }
        }
        return nil
    }

    public static func recognize(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.006
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (request.results ?? []).compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let bb = obs.boundingBox
            let rect = CGRect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h)
            return OCRLine(text: cand.string, rect: rect, color: .other, confidence: cand.confidence)
        }
    }

    private static let keywords = ["item level", "requires", "stack size", "quality", "corrupted",
                                   "unidentified", "level:", "right click", "energy shield", "armour",
                                   "evasion", "damage", "resistance", "maximum life"]

    public static func locateTooltip(_ lines: [OCRLine], cursor: CGPoint?) -> [OCRLine] {
        let usable = lines.filter { l in
            l.rect.height >= 10 && l.rect.height <= 140 && l.text.filter({ $0.isLetter || $0.isNumber }).count >= 2
        }.sorted { $0.rect.minY < $1.rect.minY }
        // Only lines with words seed clusters: stash page numbers / stack counts ("• 10") line up
        // vertically too and used to out-vote the real tooltip.
        // Tooltip text sits on a near-black panel (measured 4-36); stash tab labels and world text don't (48+).
        let isDark = { (l: OCRLine) in (l.background ?? 0) <= 45 }
        let wordedAll = usable.filter { $0.text.filter(\.isLetter).count >= 3 }
        let worded = wordedAll.contains(where: isDark) ? wordedAll.filter(isDark) : wordedAll

        struct Cluster { var lines: [OCRLine]; var cx: CGFloat; var maxY: CGFloat }
        var clusters: [Cluster] = []
        for l in worded {
            let h = l.rect.height
            var bestIdx: Int?
            var bestGap = CGFloat.infinity
            for (i, c) in clusters.enumerated() {
                let tol = max(10, 1.1 * h)
                let gap = l.rect.minY - c.maxY
                guard abs(c.cx - l.rect.midX) < tol, gap > -0.5 * h, gap < 4.0 * h else { continue }
                if gap < bestGap { bestGap = gap; bestIdx = i }
            }
            if let i = bestIdx {
                clusters[i].lines.append(l)
                let cxs = clusters[i].lines.map(\.rect.midX).sorted()
                clusters[i].cx = cxs[cxs.count / 2]
                clusters[i].maxY = max(clusters[i].maxY, l.rect.maxY)
            } else {
                clusters.append(Cluster(lines: [l], cx: l.rect.midX, maxY: l.rect.maxY))
            }
        }

        func score(_ c: Cluster) -> Double {
            var s = Double(c.lines.count)
            let text = c.lines.map { $0.text.lowercased() }.joined(separator: "\n")
            for k in keywords where text.contains(k) { s += 2 }
            // Tooltips start with a coloured name (rare/unique/magic/currency/gem).
            if let top = c.lines.min(by: { $0.rect.minY < $1.rect.minY }),
               [.rare, .unique, .magic, .currency, .gem].contains(top.color) { s += 4 }
            if c.lines.count >= 2, c.lines.contains(where: { $0.color == .magic }) { s += 2 }
            // Stacks of short labels (stash tab names, UI buttons) look like tooltips but aren't.
            let avgLetters = Double(c.lines.map { $0.text.filter(\.isLetter).count }.reduce(0, +)) / Double(c.lines.count)
            if avgLetters < 8 { s -= 4 }
            // PoE text in tooltips is centred; the area/map overlay is right-aligned (constant right edge).
            if c.lines.count >= 4 {
                func spread(_ v: [CGFloat]) -> Double {
                    let m = v.reduce(0, +) / CGFloat(v.count)
                    return Double(sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / CGFloat(v.count)))
                }
                let right = spread(c.lines.map(\.rect.maxX)), mid = spread(c.lines.map(\.rect.midX))
                if right < 0.5 * mid { s -= 20 }
            }
            if let cursor {
                let r = c.lines.reduce(CGRect.null) { $0.union($1.rect) }
                let dx = max(r.minX - cursor.x, 0, cursor.x - r.maxX)
                let dy = max(r.minY - cursor.y, 0, cursor.y - r.maxY)
                // Mild: stash tooltips are drawn well away from the cursor.
                s -= Double(hypot(dx, dy)) / 400
            }
            return s
        }
        if ProcessInfo.processInfo.environment["POE_DEBUG_CLUSTERS"] != nil {
            for c in clusters.sorted(by: { score($0) > score($1) }).prefix(5) {
                print(String(format: "cluster %.1f cx=%.0f n=%d: ", score(c), c.cx, c.lines.count) + c.lines.prefix(4).map { "[\($0.color.rawValue)] \($0.text)" }.joined(separator: " / "))
            }
        }
        guard let best = clusters.filter({ $0.lines.count >= 1 }).max(by: { score($0) < score($1) }) else { return [] }

        // Pull in fragments Vision split off the same row (e.g. "Armour:" and "412"),
        // and lines in the tooltip's vertical span that are centred slightly off.
        let span = best.lines.reduce(CGRect.null) { $0.union($1.rect) }
        let members = Set(best.lines.map { "\($0.rect)" })
        var extra: [OCRLine] = []
        for l in usable where !members.contains("\(l.rect)") {
            // Inside the tooltip's vertical span a lighter background is fine (header frames over bright
            // scenes measure up to ~60); outside it only dark-panel text may be added.
            let inside = l.rect.minY >= span.minY - 2 && l.rect.maxY <= span.maxY + 2
            guard isDark(l) || (inside && (l.background ?? 0) <= 90) else { continue }
            guard l.rect.minY >= span.minY - 4, l.rect.maxY <= span.maxY + 4,
                  l.rect.minX >= span.minX - span.width * 0.15, l.rect.maxX <= span.maxX + span.width * 0.15 else { continue }
            extra.append(l)
        }
        // The item name sits in the header frame, which can be lighter than the body. Keep a coloured,
        // centred line hugging the top of the tooltip even if its background is a bit brighter.
        if let top = best.lines.min(by: { $0.rect.minY < $1.rect.minY }) {
            let above = usable.filter { l in
                let gap = top.rect.minY - l.rect.maxY
                return gap >= -2 && gap < 0.8 * top.rect.height && abs(l.rect.midX - best.cx) < max(14, 1.1 * l.rect.height)
                    && (l.background ?? 0) <= 70 && [.rare, .unique, .magic, .currency, .gem, .white].contains(l.color)
            }
            if let nameLine = above.max(by: { $0.rect.minY < $1.rect.minY }), !extra.contains(nameLine) { extra.append(nameLine) }
        }
        return mergeRows(best.lines, extras: extra, centerX: best.cx)
    }

    /// Merges OCR boxes that sit on the same text row into one line, left to right.
    /// Extra fragments are only kept when the merged row stays centred on the tooltip (text is centre-aligned),
    /// which drops background text such as an "INVENTORY" header next to the item class line.
    static func mergeRows(_ members: [OCRLine], extras: [OCRLine] = [], centerX: CGFloat? = nil) -> [OCRLine] {
        let memberKeys = Set(members.map { "\($0.rect)" })
        let lines = members + extras
        let sorted = lines.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[OCRLine]] = []
        for l in sorted {
            if let last = rows.last?.last,
               abs(last.rect.midY - l.rect.midY) < 0.45 * min(last.rect.height, l.rect.height) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.compactMap { fullRow -> OCRLine? in
            var row = fullRow
            if let cx = centerX {
                let h = row.map(\.rect.height).max() ?? 20
                let union = row.reduce(CGRect.null) { $0.union($1.rect) }
                if abs(union.midX - cx) > max(14, 1.2 * h) {
                    row = row.filter { memberKeys.contains("\($0.rect)") }
                }
                // A row made only of extras must itself be centred.
                if row.allSatisfy({ !memberKeys.contains("\($0.rect)") }) {
                    let u = row.reduce(CGRect.null) { $0.union($1.rect) }
                    if row.isEmpty || abs(u.midX - cx) > max(14, 1.2 * h) { return nil }
                }
                if row.isEmpty { return nil }
            }
            let r = row.sorted { $0.rect.minX < $1.rect.minX }
            guard r.count > 1 else { return r[0] }
            var merged = r[0]
            merged.text = r.map(\.text).joined(separator: " ")
            merged.rect = r.reduce(CGRect.null) { $0.union($1.rect) }
            // Prefer the colour of the widest fragment (labels are grey, values white).
            merged.color = r.max(by: { $0.rect.width < $1.rect.width })!.color
            merged.confidence = r.map(\.confidence).min() ?? merged.confidence
            return merged
        }
    }
}

/// RGBA copy of a CGImage for colour sampling.
struct PixelBuffer {
    let width: Int, height: Int
    let data: [UInt8]

    init?(image: CGImage) {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        data = buf
    }

    /// Median brightness of a thin band just outside the text box (left/right/above/below margins).
    func backgroundLevel(in rect: CGRect) -> Double {
        let pad = max(4, rect.height * 0.35)
        let outer = rect.insetBy(dx: -pad, dy: -pad * 0.6)
        var values: [Int] = []
        let x0 = max(0, Int(outer.minX)), x1 = min(width, Int(outer.maxX))
        let y0 = max(0, Int(outer.minY)), y1 = min(height, Int(outer.maxY))
        guard x1 > x0, y1 > y0 else { return 255 }
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) where !rect.contains(CGPoint(x: x, y: y)) {
                let i = (y * width + x) * 4
                values.append(max(Int(data[i]), Int(data[i + 1]), Int(data[i + 2])))
            }
        }
        guard !values.isEmpty else { return 255 }
        values.sort()
        return Double(values[values.count / 2])
    }

    /// Average colour of the brightest ~12% of pixels in the rect (the glyph cores).
    func textColor(in rect: CGRect) -> TextColor {
        let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return .other }
        var samples: [(Int, Int, Int, Int)] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                // Max channel as "brightness" so saturated blue/red text ranks with white text.
                samples.append((max(r, g, b), r, g, b))
            }
        }
        samples.sort { $0.0 > $1.0 }
        let n = max(1, samples.count / 8)
        var sr = 0, sg = 0, sb = 0
        for s in samples.prefix(n) { sr += s.1; sg += s.2; sb += s.3 }
        let (ar, ag, ab) = (Double(sr) / Double(n), Double(sg) / Double(n), Double(sb) / Double(n))
        if ProcessInfo.processInfo.environment["POE_DEBUG_COLORS"] != nil {
            print(String(format: "rgb %3.0f %3.0f %3.0f -> %@ @ %.0f,%.0f", ar, ag, ab, TextColor.classify(r: ar, g: ag, b: ab).rawValue, rect.minX, rect.minY))
        }
        return TextColor.classify(r: ar, g: ag, b: ab)
    }
}
