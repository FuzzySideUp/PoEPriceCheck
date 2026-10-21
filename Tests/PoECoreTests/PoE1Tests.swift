import XCTest
@testable import PoECore

/// Path of Exile 1: bundled data, parsing (no item class line, no item level without Alt) and the fuzzy query.
final class PoE1ParserTests: XCTestCase {
    let data = TestData.poe1Data

    func rareChest() -> ParsedItem {
        var lines = TestData.lines("""
        Kraken Shell
        Vaal Regalia
        --------
        Quality: +20%
        Energy Shield: 412
        --------
        Requires Level 68, 194 Int
        --------
        +92 to maximum Life
        +86 to maximum Energy Shield
        +40% to Fire Resistance
        +31% to Cold and Lightning Resistances
        +30 to Strength
        12% increased Stun and Block Recovery
        --------
        Corrupted
        """)
        lines[0].color = .rare; lines[1].color = .rare
        return TestData.poe1Parser.parse(lines)
    }

    func testRareBodyArmour() {
        let item = rareChest()
        XCTAssertEqual(item.rarity, .rare)
        XCTAssertEqual(item.name, "Kraken Shell")
        XCTAssertEqual(item.baseType, "Vaal Regalia")
        XCTAssertEqual(item.category, "armour.chest")
        XCTAssertNil(item.itemLevel)
        XCTAssertEqual(item.quality, 20)
        XCTAssertTrue(item.corrupted)
        XCTAssertEqual(item.mods.count, 6)
    }

    func testWeaponClassLineSkipped() {
        var lines = TestData.lines("""
        Doom Bite
        Jewelled Foil
        --------
        Thrusting One Handed Sword
        Physical Damage: 46-86
        Critical Strike Chance: 5.50%
        Attacks per Second: 1.60
        --------
        Requires Level 68, 212 Dex
        --------
        +25% to Global Critical Strike Multiplier
        --------
        150% increased Physical Damage
        Adds 10 to 20 Physical Damage
        +30% to Global Critical Strike Multiplier
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let item = TestData.poe1Parser.parse(lines)
        XCTAssertEqual(item.category, "weapon.rapier")
        XCTAssertEqual(item.properties["Physical Damage"], "46-86")
        XCTAssertEqual(item.mods.map(\.kind), [.implicit, .explicit, .explicit, .explicit])
    }

    func testCraftedModAndEnchantBlock() {
        var lines = TestData.lines("""
        Grim Visage
        Hubris Circlet
        --------
        Energy Shield: 220
        --------
        Purity of Elements has 20% increased Aura Effect
        --------
        +80 to maximum Life
        +38% to Cold Resistance
        +1 to Level of Socketed Gems
        """)
        lines[0].color = .rare; lines[1].color = .rare
        lines[5].color = .enchant
        lines[7].color = .magic
        lines[8].color = .magic
        lines[9].color = .enchant
        let item = TestData.poe1Parser.parse(lines)
        XCTAssertEqual(item.mods.first?.kind, .enchant)
        XCTAssertEqual(item.mods.last?.kind, .crafted)
        XCTAssertEqual(item.mods[1].kind, .explicit)   // not an implicit block
    }

    func testCurrencyAndDivinationCard() {
        var lines = TestData.lines("""
        Chaos Orb
        --------
        Stack Size: 143/20
        --------
        Reforges a rare item with new random modifiers
        """)
        lines[0].color = .currency
        let orb = TestData.poe1Parser.parse(lines)
        XCTAssertEqual(orb.rarity, .currency)
        XCTAssertEqual(orb.name, "Chaos Orb")
        XCTAssertEqual(orb.stackSize, 143)

        var card = TestData.lines("""
        The Doctor
        --------
        Stack Size: 1/8
        """)
        card[0].color = .white
        XCTAssertEqual(TestData.poe1Parser.parse(card).rarity, .currency)
    }

    func testUnique() {
        var lines = TestData.lines("""
        Tabula Rasa
        Simple Robe
        --------
        Item has no Level requirement and Energy Shield
        --------
        Item has no Attribute Requirements
        --------
        Mirrored
        """)
        lines[0].color = .unique; lines[1].color = .unique
        let item = TestData.poe1Parser.parse(lines)
        XCTAssertEqual(item.rarity, .unique)
        XCTAssertEqual(item.name, "Tabula Rasa")
        XCTAssertEqual(item.baseType, "Simple Robe")
        XCTAssertEqual(item.category, "armour.chest")
    }

    func testStatTemplates() {
        XCTAssertEqual(data.matchStat("+92 to maximum Life")?.stats.first { $0.type == "explicit" }?.id, "explicit.stat_3299347043")
        XCTAssertEqual(data.matchStat("+1 to Level of Socketed Gems")?.values, [1])
        XCTAssertNotNil(data.matchStat("+28% chance to Suppress Spell Damage"))
        XCTAssertNotNil(data.matchStat("+31% to Cold and Lightning Resistances"))
        for p in ["pseudo.pseudo_total_life", "pseudo.pseudo_total_elemental_resistance", "pseudo.pseudo_total_chaos_resistance",
                  "pseudo.pseudo_total_energy_shield", "pseudo.pseudo_total_strength", "pseudo.pseudo_total_mana"] {
            XCTAssertNotNil(data.pseudoStats[p], p)
        }
    }
}

final class PoE1QueryTests: XCTestCase {
    let data = TestData.poe1Data

    func testFuzzyBodyArmour() throws {
        var item = PoE1ParserTests().rareChest()
        item.corrupted = false
        var s = RareQueryBuilder(data: data, margin: 0.1).build(item)
        XCTAssertEqual(s.game, .poe1)

        // Life pseudo counts Strength / 2 in PoE 1.
        let life = try XCTUnwrap(s.filters.first { $0.target == .stat("pseudo.pseudo_total_life") })
        XCTAssertEqual(life.rolled, 107)
        XCTAssertTrue(life.enabled)
        let res = try XCTUnwrap(s.filters.first { $0.target == .stat("pseudo.pseudo_total_elemental_resistance") })
        XCTAssertEqual(res.rolled, 102)
        // Local ES is covered by the Energy Shield property.
        XCTAssertNil(s.filters.first { $0.label == "# to maximum Energy Shield" })
        XCTAssertEqual(s.filters.first { $0.target == .equipment("es") }?.rolled, 412)
        XCTAssertFalse(s.useItemLevel)

        s.links = 6
        let json = String(data: try JSONSerialization.data(withJSONObject: s.queryJSON(), options: .sortedKeys), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"armour_filters\":{\"filters\":{\"es\":{\"min\":370}}}"), json)
        XCTAssertTrue(json.contains("\"socket_filters\":{\"filters\":{\"links\":{\"min\":6}}}"), json)
        XCTAssertFalse(json.contains("equipment_filters"))
        XCTAssertFalse(json.contains("\"max\""))
        XCTAssertFalse(json.contains("ilvl"))
    }

    func testWeaponFiltersAndWeights() throws {
        var lines = TestData.lines("""
        Doom Bite
        Jewelled Foil
        --------
        Thrusting One Handed Sword
        Physical Damage: 46-86
        Attacks per Second: 1.60
        --------
        150% increased Physical Damage
        +30% to Global Critical Strike Multiplier
        +28% chance to Suppress Spell Damage
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let s = RareQueryBuilder(data: data).build(TestData.poe1Parser.parse(lines))
        XCTAssertEqual(s.filters.first { $0.target == .equipment("pdps") }?.rolled, 106)
        XCTAssertTrue(s.filters.contains { $0.label.contains("Critical Strike Multiplier") && $0.enabled })
        XCTAssertTrue(s.filters.contains { $0.label.contains("Suppress") && $0.enabled })
        let json = String(data: try JSONSerialization.data(withJSONObject: s.queryJSON(), options: .sortedKeys), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"weapon_filters\""), json)
        XCTAssertTrue(json.contains("weapon.rapier"))
    }

    func testUnidentifiedHasNoTier() throws {
        var item = PoE1ParserTests().rareChest()
        item.unidentified = true
        let json = String(data: try JSONSerialization.data(withJSONObject: RareQueryBuilder(data: data).build(item).queryJSON()), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"identified\":{\"option\":\"false\"}"))
        XCTAssertFalse(json.contains("unidentified_tier"))
    }

    func testURLs() {
        XCTAssertEqual(Game.poe1.searchURL(league: "Allflame").absoluteString, "https://www.pathofexile.com/api/trade/search/Allflame")
        XCTAssertEqual(Game.poe2.searchURL(league: "Rise of the Abyssal").absoluteString,
                       "https://www.pathofexile.com/api/trade2/search/poe2/Rise%20of%20the%20Abyssal")
        XCTAssertEqual(Game.poe1.webURL(league: "Allflame", queryId: "abc").absoluteString,
                       "https://www.pathofexile.com/trade/search/Allflame/abc")
    }
}

final class GameDetectorTests: XCTestCase {
    let detector = TestData.detector

    func testLeagueOnScreenWins() {
        let tooltip = TestData.lines("Divine Orb\n--------\nStack Size: 3/20")
        let overlay = [OCRLine(text: "Allflame League")]
        let d = detector.decide(tooltip: tooltip, allLines: overlay + tooltip,
                                leagues: [.poe1: ["Allflame", "Standard"], .poe2: ["Rise of the Abyssal", "Standard"]], last: .poe2)
        XCTAssertEqual(d.game, .poe1)
        XCTAssertEqual(d.league, "Allflame")
        // "Standard" exists in both games and decides nothing.
        let std = detector.decide(tooltip: tooltip, allLines: [OCRLine(text: "Standard League")] + tooltip,
                                  leagues: [.poe1: ["Standard"], .poe2: ["Standard"]], last: .poe2)
        XCTAssertEqual(std.game, .poe2)
    }

    func testWording() {
        XCTAssertEqual(detector.decide(tooltip: PoE1Lines.rareChest, allLines: [], leagues: [:], last: .poe2).game, .poe1)
        var ring = TestData.lines("Storm Loop\nGold Ring\nRing\n--------\nRequires: Level 40\n--------\n+60 to maximum Life")
        ring[0].color = .rare; ring[1].color = .rare
        let d = detector.decide(tooltip: ring, allLines: [], leagues: [:], last: .poe1)
        XCTAssertEqual(d.game, .poe2)
        XCTAssertEqual(d.item.baseType, "Gold Ring")
    }

    func testSharedItemKeepsLastGame() {
        let orb = TestData.lines("Chaos Orb\n--------\nStack Size: 3/20")
        XCTAssertEqual(detector.decide(tooltip: orb, allLines: [], leagues: [:], last: .poe1).game, .poe1)
        XCTAssertEqual(detector.decide(tooltip: orb, allLines: [], leagues: [:], last: .poe2).game, .poe2)
    }

    func testItemKnownInOneGame() {
        var lines = TestData.lines("Tabula Rasa\nSimple Robe\n--------\nItem has no Level requirement and Energy Shield")
        lines[0].color = .unique; lines[1].color = .unique
        XCTAssertEqual(detector.decide(tooltip: lines, allLines: [], leagues: [:], last: .poe2).game, .poe1)
    }
}

enum PoE1Lines {
    static var rareChest: [OCRLine] {
        var lines = TestData.lines("""
        Kraken Shell
        Vaal Regalia
        --------
        Energy Shield: 412
        --------
        Requires Level 68, 194 Int
        --------
        +92 to maximum Life
        """)
        lines[0].color = .rare; lines[1].color = .rare
        return lines
    }
}
