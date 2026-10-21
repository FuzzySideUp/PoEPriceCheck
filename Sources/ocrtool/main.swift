import CoreGraphics
import Foundation
import ImageIO
import PoECore

// Debug tool: ocrtool <image.png> [cursorX cursorY] [--all]
// Prints OCR'd tooltip lines with colours, the parsed item and the fuzzy rare search it would run.
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ocrtool <image> [cursorX cursorY] [--all]")
    exit(1)
}
let dataDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Data/poe2").standardized
let data = try GameData(directory: dataDir)
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("cannot read image"); exit(1)
}
var cursor: CGPoint?
if args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) { cursor = CGPoint(x: x, y: y) }
let result = try TooltipReader.read(image: image, cursor: cursor)
print(String(format: "image %dx%d  OCR %.2fs  tooltip %@", image.width, image.height, result.ocrSeconds, "\(result.tooltipRect)"))
if args.contains("--all") {
    print("--- all lines")
    for l in result.allLines { print(String(format: "%5.0f,%5.0f %4.0fx%3.0f bg%3.0f %-10@ %@", l.rect.minX, l.rect.minY, l.rect.width, l.rect.height, l.background ?? -1, l.color.rawValue, l.text)) }
}
print("--- tooltip")
for l in result.lines { print(String(format: "%5.0f,%5.0f %4.0fx%3.0f %-10@ %@", l.rect.minX, l.rect.minY, l.rect.width, l.rect.height, l.color.rawValue, l.text)) }
let item = ItemParser(data: data).parse(result.lines)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
var printable = item; printable.rawLines = []
print("--- parsed"); print(String(data: try enc.encode(printable), encoding: .utf8)!)
if item.rarity == .rare || item.rarity == .magic {
    let s = RareQueryBuilder(data: data).build(item)
    print("--- rare search")
    for f in s.filters { print("\(f.enabled ? "[x]" : "[ ]") w\(f.weight) \(f.display(margin: s.margin))   <- \(f.sources)") }
    let q = try JSONSerialization.data(withJSONObject: s.queryJSON(), options: [.prettyPrinted, .sortedKeys])
    print(String(data: q, encoding: .utf8)!)
}

if args.contains("--price") {
    let ua = "PoEPriceCheck/0.1 (macOS; personal OCR price-check overlay; ocrtool)"
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("poepc-ocrtool")
    let ninja = NinjaClient(cacheDirectory: cache, userAgent: ua)
    let league = try await ninja.currentLeague()
    let snap = try await ninja.ensure(league: league)
    func fmt(_ d: Double) -> String { d >= 1 ? String(format: "%.1f div", d) : String(format: "%.0f ex", d * snap.exaltedPerDivine) }
    print("--- price (\(league))")
    switch item.rarity {
    case .rare, .magic:
        let r = try await TradeClient(userAgent: ua).price(RareQueryBuilder(data: data).build(item), league: league,
                                                          autoRelax: true, currencyRates: snap.currencyById)
        print("total \(r.total) relaxed: \(r.search?.relaxNotes ?? [])")
        for f in r.search?.filters ?? [] where f.enabled { print("  used: \(f.display(margin: r.search!.margin))") }
        print("  prices: " + r.listings.map { "\($0.amount) \($0.currency)" }.joined(separator: ", "))
        print("  \(r.webURL)")
    default:
        if let p = await ninja.lookup(name: item.name ?? "", baseType: item.rarity == .unique ? item.baseType : nil, corrupted: item.corrupted) {
            print("ninja: \(p.name) \(fmt(p.divine)) each (\(p.category))" + (item.stackSize.map { " stack \($0): " + fmt(p.divine * Double($0)) } ?? ""))
        } else {
            print("ninja: no price")
        }
    }
}
