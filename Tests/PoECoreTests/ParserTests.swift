import XCTest
@testable import PoECore

final class ParserTests: XCTestCase {
    let data = TestData.gameData

    func testRareBootsFromText() {
        var lines = TestData.lines("""
        Gale Stride
        Bound Sandals
        --------
        Evasion Rating: 134
        Requires: Level 52, 41 Dex
        Item Level: 79
        --------
        +97 to maximum Life
        +38% to Fire Resistance
        +12% to Cold Resistance
        +15% to Lightning Resistance
        30% increased Movement Speed
        +24 to Dexterity
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.rarity, .rare)
        XCTAssertEqual(item.name, "Gale Stride")
        XCTAssertEqual(item.baseType, "Bound Sandals")
        XCTAssertEqual(item.category, "armour.boots")
        XCTAssertEqual(item.itemLevel, 79)
        XCTAssertEqual(item.properties["Evasion Rating"], "134")
        XCTAssertEqual(item.mods.count, 6)
        XCTAssertEqual(item.mods.first?.values, [97])
        XCTAssertTrue(item.mods.allSatisfy { $0.kind == .explicit })
    }

    func testRareWithoutColoursUsesBaseLookup() {
        let item = TestData.parser.parse(TestData.lines("""
        Gale Stride
        Bound Sandals
        --------
        Item Level: 79
        --------
        +97 to maximum Life
        """))
        XCTAssertEqual(item.rarity, .rare)
        XCTAssertEqual(item.baseType, "Bound Sandals")
    }

    func testImplicitBlockDetected() {
        var lines = TestData.lines("""
        Storm Loop
        Gold Ring
        --------
        Requires: Level 40
        Item Level: 80
        --------
        12% increased Rarity of Items found
        --------
        +60 to maximum Life
        +30% to Lightning Resistance
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.category, "accessory.ring")
        XCTAssertEqual(item.mods.map(\.kind), [.implicit, .explicit, .explicit])
    }

    func testCurrencyStack() {
        var lines = TestData.lines("""
        Exalted Orb
        --------
        Stack Size: 7 / 20
        --------
        Augments a Rare item with a new random modifier
        --------
        Right click this item then left click a rare item to apply it.
        """)
        lines[0].color = .currency
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.rarity, .currency)
        XCTAssertEqual(item.name, "Exalted Orb")
        XCTAssertEqual(item.stackSize, 7)
        XCTAssertEqual(item.maxStackSize, 20)
        XCTAssertTrue(item.mods.isEmpty)
    }

    func testUniqueWithFlavourText() {
        var lines = TestData.lines("""
        Temporalis
        Silk Robe
        --------
        Energy Shield: 241
        Item Level: 80
        --------
        +120 to maximum Energy Shield
        +15% to all Elemental Resistances
        --------
        The final element the tale-women
        mastered was Time itself.
        """)
        lines[0].color = .unique; lines[1].color = .unique
        lines[lines.count - 1].color = .unique; lines[lines.count - 2].color = .unique
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.rarity, .unique)
        XCTAssertEqual(item.name, "Temporalis")
        XCTAssertEqual(item.baseType, "Silk Robe")
        XCTAssertEqual(item.mods.count, 2)
    }

    func testOCRNoiseInUniqueAndBaseNames() {
        let item = TestData.parser.parse(TestData.lines("""
        Ternporalis
        Silk Rob
        --------
        Item Level: 80
        """))
        XCTAssertEqual(item.rarity, .unique)
        XCTAssertEqual(item.name, "Temporalis")
        XCTAssertEqual(item.baseType, "Silk Robe")
    }

    func testMagicItemBaseExtraction() {
        var lines = TestData.lines("""
        Hale Bound Sandals of the Penguin
        --------
        Item Level: 30
        --------
        +25 to maximum Life
        +12% to Cold Resistance
        """)
        lines[0].color = .magic
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.rarity, .magic)
        XCTAssertEqual(item.baseType, "Bound Sandals")
        XCTAssertEqual(item.mods.count, 2)
    }

    func testGem() {
        var lines = TestData.lines("""
        Fireball
        --------
        Spell, Projectile, AoE, Fire
        Level: 11
        Quality: +20%
        """)
        lines[0].color = .gem
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.rarity, .gem)
        XCTAssertEqual(item.name, "Fireball")
        XCTAssertEqual(item.gemLevel, 11)
        XCTAssertEqual(item.quality, 20)
    }

    func testCorruptedFlag() {
        let item = TestData.parser.parse(TestData.lines("""
        Gale Stride
        Bound Sandals
        --------
        Item Level: 79
        --------
        +97 to maximum Life
        --------
        Corrupted
        """))
        XCTAssertTrue(item.corrupted)
    }
}

final class AdvancedViewTests: XCTestCase {
    /// Alt held (or advanced mod descriptions on): roll ranges after values, class and item level on one line.
    func testRollRangesAndItemLevel() {
        var lines = TestData.lines("""
        Glyph Urge
        Bound Sandals
        --------
        Boots: Item Level 81
        Energy Shield: 162
        --------
        99(92-100)% increased Energy Shield
        +80(70-84) to maximum Life
        30% increased Movement Speed
        8.4(6.1-9) Life Regeneration per second
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let item = TestData.parser.parse(lines)
        XCTAssertEqual(item.itemLevel, 81)
        XCTAssertEqual(item.mods.map(\.values), [[99], [80], [30], [8.4]])
        XCTAssertEqual(ItemParser.stripRollRanges("+40(36-40)% to Fire Resistance"), "+40% to Fire Resistance")
        XCTAssertEqual(ItemParser.stripRollRanges("Level: 20 (Max)"), "Level: 20 (Max)")
    }
}

final class StatMatchTests: XCTestCase {
    let data = TestData.gameData

    func testExactMatches() {
        XCTAssertEqual(data.matchStat("+97 to maximum Life")?.stats.first { $0.type == "explicit" }?.id, "explicit.stat_3299347043")
        XCTAssertEqual(data.matchStat("30% increased Movement Speed")?.values, [30])
        XCTAssertEqual(data.matchStat("Adds 5 to 10 Physical Damage to Attacks")?.values, [5, 10])
        XCTAssertNotNil(data.matchStat("+2 to Level of all Spell Skills"))
    }

    func testOCRNoise() {
        // "Lightninq" / missing letters
        let m = data.matchStat("+15% to Lightninq Resistance")
        XCTAssertEqual(m?.stats.first { $0.type == "explicit" }?.id, "explicit.stat_1671376347")
        XCTAssertEqual(m?.values, [15])
    }

    func testReducedMapsToIncreasedNegated() {
        let m = data.matchStat("10% reduced Attribute Requirements")
        XCTAssertNotNil(m)
    }

    func testLocalPreference() {
        let m = data.matchStat("+80 to maximum Energy Shield")!
        XCTAssertEqual(data.pick(m.stats, kind: .explicit, preferLocal: true)?.id, "explicit.stat_4052037485")
        XCTAssertEqual(data.pick(m.stats, kind: .explicit, preferLocal: false)?.id, "explicit.stat_3489782002")
    }

    func testNonStatLinesDoNotMatch() {
        XCTAssertNil(data.matchStat("The final element the tale-women"))
        XCTAssertNil(data.matchStat("Right click this item then left click a rare item to apply it."))
    }
}

final class NonItemTests: XCTestCase {
    func testWebPageTextIsNotAnItem() {
        var lines = TestData.lines("$5,000 $5,800\n--------\nFree shipping")
        lines[0].color = .white
        XCTAssertEqual(TestData.parser.parse(lines).rarity, .unknown)
    }
}
