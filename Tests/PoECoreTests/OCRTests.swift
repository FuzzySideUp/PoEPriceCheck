import XCTest
@testable import PoECore

/// Runs rendered tooltips through Vision OCR + tooltip location + parsing.
final class SyntheticOCRTests: XCTestCase {
    typealias L = TooltipRenderer.Line

    func run(_ blocks: [[L]]) throws -> ParsedItem {
        let (image, cursor) = TooltipRenderer.render(blocks)
        let r = try TooltipReader.read(image: image, cursor: cursor)
        return TestData.parser.parse(r.lines)
    }

    func testRareBoots() throws {
        let item = try run([
            [L(text: "Gale Stride", color: .rare), L(text: "Bound Sandals", color: .rare)],
            [L(text: "Evasion Rating: 134", color: .white), L(text: "Requires: Level 52, 41 Dex", color: .grey),
             L(text: "Item Level: 79", color: .grey)],
            [L(text: "+97 to maximum Life", color: .magic), L(text: "+38% to Fire Resistance", color: .magic),
             L(text: "+12% to Cold Resistance", color: .magic), L(text: "30% increased Movement Speed", color: .magic)],
        ])
        XCTAssertEqual(item.rarity, .rare)
        XCTAssertEqual(item.baseType, "Bound Sandals")
        XCTAssertEqual(item.itemLevel, 79)
        XCTAssertEqual(item.mods.count, 4)
        XCTAssertEqual(item.mods.first?.values, [97])
    }

    func testCurrency() throws {
        let item = try run([
            [L(text: "Exalted Orb", color: .currency)],
            [L(text: "Stack Size: 7 / 20", color: .white)],
            [L(text: "Augments a Rare item with a new random modifier", color: .grey)],
        ])
        XCTAssertEqual(item.rarity, .currency)
        XCTAssertEqual(item.name, "Exalted Orb")
        XCTAssertEqual(item.stackSize, 7)
    }

    func testUnique() throws {
        let item = try run([
            [L(text: "Temporalis", color: .unique), L(text: "Silk Robe", color: .unique)],
            [L(text: "Energy Shield: 241", color: .white), L(text: "Item Level: 80", color: .grey)],
            [L(text: "+120 to maximum Energy Shield", color: .magic), L(text: "+15% to all Elemental Resistances", color: .magic)],
            [L(text: "The final element the tale-women", color: .unique)],
        ])
        XCTAssertEqual(item.rarity, .unique)
        XCTAssertEqual(item.name, "Temporalis")
        XCTAssertEqual(item.baseType, "Silk Robe")
    }

    func testGem() throws {
        let item = try run([
            [L(text: "Fireball", color: .gem)],
            [L(text: "Spell, Projectile, AoE, Fire", color: .grey), L(text: "Level: 11", color: .white)],
        ])
        XCTAssertEqual(item.rarity, .gem)
        XCTAssertEqual(item.gemLevel, 11)
    }
}

/// Real captures: Fixtures/screens/<name>.jpg|png with <name>.expected.json
/// ({"game": "poe1"|"poe2" (default poe2), "autoShared" (item exists in both games: Auto keeps the last game), "rarity", "name", "baseType", "itemLevel", "stackSize", "minMods", "corrupted",
///   "enabledStats": [display strings], "cursor": [x, y]}).
final class FixtureOCRTests: XCTestCase {
    struct Expected: Decodable {
        var game: String?; var autoShared: Bool?; var rarity: String?; var name: String?; var baseType: String?
        var itemLevel: Int?; var stackSize: Int?; var minMods: Int?; var corrupted: Bool?; var unidentified: Bool?
        var enabledStats: [String]?; var cursor: [Double]?
    }

    func testFixtures() throws {
        let dir = TestData.root.appendingPathComponent("Fixtures/screens")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let cases = files.filter { $0.lastPathComponent.hasSuffix(".expected.json") }
        try XCTSkipIf(cases.isEmpty, "no real fixtures yet")
        for exp in cases.sorted(by: { $0.path < $1.path }) {
            let name = exp.lastPathComponent.replacingOccurrences(of: ".expected.json", with: "")
            let image = ["jpg", "png"].lazy.compactMap { TestData.loadImage(dir.appendingPathComponent("\(name).\($0)")) }.first
            guard let image else { XCTFail("missing image for \(name)"); continue }
            let e = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: exp))
            let cursor = e.cursor.map { CGPoint(x: $0[0], y: $0[1]) }
            let game = e.game.flatMap(Game.init(rawValue:)) ?? .poe2
            let data = TestData.data(game)
            let read = try TooltipReader.read(image: image, cursor: cursor)
            let item = ItemParser(data: data).parse(read.lines)
            // Auto mode must pick this fixture's game even when the last check was the other game.
            let other: Game = game == .poe1 ? .poe2 : .poe1
            let detected = TestData.detector.decide(tooltip: read.lines, allLines: read.allLines, leagues: [:],
                                                    last: e.autoShared == true ? game : other)
            XCTAssertEqual(detected.game, game, "\(name): auto picked \(detected.game) (\(detected.reason))")
            if let r = e.rarity { XCTAssertEqual(item.rarity.rawValue, r, name) }
            if let n = e.name { XCTAssertEqual(item.name, n, name) }
            if let b = e.baseType { XCTAssertEqual(item.baseType, b, name) }
            if let i = e.itemLevel { XCTAssertEqual(item.itemLevel, i, name) }
            if let s = e.stackSize { XCTAssertEqual(item.stackSize, s, name) }
            if let m = e.minMods { XCTAssertGreaterThanOrEqual(item.mods.count, m, name) }
            if let c = e.corrupted { XCTAssertEqual(item.corrupted, c, name) }
            if let u = e.unidentified { XCTAssertEqual(item.unidentified, u, name) }
            if let wanted = e.enabledStats {
                let s = RareQueryBuilder(data: data).build(item)
                let enabled = s.filters.filter(\.enabled).map { $0.display(margin: s.margin) }
                for w in wanted { XCTAssertTrue(enabled.contains(w), "\(name): \(w) not in \(enabled)") }
            }
        }
    }
}
