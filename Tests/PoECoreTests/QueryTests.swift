import XCTest
@testable import PoECore

final class QueryTests: XCTestCase {
    let data = TestData.gameData

    func bootsItem() -> ParsedItem {
        var lines = TestData.lines("""
        Gale Stride
        Bound Sandals
        --------
        Evasion Rating: 134
        Item Level: 79
        --------
        +97 to maximum Life
        +38% to Fire Resistance
        +12% to Cold Resistance
        +15% to Lightning Resistance
        30% increased Movement Speed
        +24 to Dexterity
        +18 to Evasion Rating
        +3 Life gained on Kill
        """)
        lines[0].color = .rare; lines[1].color = .rare
        return TestData.parser.parse(lines)
    }

    func filter(_ s: RareSearch, _ id: String) -> StatFilter? {
        s.filters.first { if case let .stat(x) = $0.target { return x == id }; if case let .equipment(x) = $0.target { return x == id }; return false }
    }

    func testFuzzyBootsSearch() throws {
        let s = RareQueryBuilder(data: data, margin: 0.1).build(bootsItem())
        let life = try XCTUnwrap(filter(s, "pseudo.pseudo_total_life"))
        XCTAssertEqual(life.rolled, 97)
        XCTAssertEqual(life.minValue(margin: 0.1), 87)
        XCTAssertTrue(life.enabled)

        let res = try XCTUnwrap(filter(s, "pseudo.pseudo_total_elemental_resistance"))
        XCTAssertEqual(res.rolled, 65)
        XCTAssertEqual(res.minValue(margin: 0.1), 58)
        XCTAssertTrue(res.enabled)

        let ms = try XCTUnwrap(filter(s, "explicit.stat_2250533757"))
        XCTAssertEqual(ms.minValue(margin: 0.1), 27)
        XCTAssertTrue(ms.enabled)

        // Attribute folded into pseudo total, low priority so off by default.
        XCTAssertEqual(filter(s, "pseudo.pseudo_total_dexterity")?.enabled, false)
        // Local flat evasion is covered by the Evasion property filter.
        XCTAssertNil(filter(s, "explicit.stat_53045048"))
        XCTAssertEqual(filter(s, "ev")?.rolled, 134)
        // Junk mod present but not enabled.
        XCTAssertTrue(s.filters.filter { $0.label.contains("on Kill") }.allSatisfy { !$0.enabled })

        // Query JSON: min only, category, ilvl floor, no max anywhere.
        let json = String(data: try JSONSerialization.data(withJSONObject: s.queryJSON()), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"max\""))
        XCTAssertTrue(json.contains("armour.boots"))
        XCTAssertTrue(json.contains("\"ilvl\":{\"min\":69}"))
    }

    func testRelaxationOrder() {
        var s = RareQueryBuilder(data: data, margin: 0.1).build(bootsItem())
        var notes: [String] = []
        while let next = s.relaxed() { s = next; notes = s.relaxNotes }
        XCTAssertEqual(notes.first, "dropped item level floor")
        XCTAssertEqual(notes[1], "margin widened to 20%")
        XCTAssertEqual(s.filters.filter(\.enabled).count, 1)
        // The most valuable stat survives.
        XCTAssertEqual(s.filters.first(where: \.enabled)?.weight, 10)
    }

    func testWeaponDps() throws {
        var lines = TestData.lines("""
        Doom Bite
        Hardwood Spear
        --------
        Physical Damage: 50-90
        Attacks per Second: 1.50
        Item Level: 81
        --------
        120% increased Physical Damage
        Adds 10 to 20 Physical Damage
        +2 to Level of all Melee Skills
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let item = TestData.parser.parse(lines)
        let s = RareQueryBuilder(data: data).build(item)
        let pdps = try XCTUnwrap(filter(s, "pdps"))
        XCTAssertEqual(pdps.rolled, 105)
        XCTAssertTrue(pdps.enabled)
        XCTAssertNil(s.filters.first { $0.label.contains("increased Physical Damage") })
        XCTAssertTrue(s.filters.contains { $0.label.contains("Level of all Melee") && $0.enabled })
    }
}

final class RateLimiterTests: XCTestCase {
    func testHeadroom() async {
        let rl = RateLimiter(defaults: ["p": "3:10:60"])
        let now = Date()
        try? await rl.acquire("p")
        try? await rl.acquire("p")
        // 3 allowed by server, we keep one spare: third must wait ~10s.
        let d = await rl.delay(for: "p", now: now.addingTimeInterval(1))
        XCTAssertGreaterThan(d, 8)
    }

    func testRetryAfter() async {
        let rl = RateLimiter(defaults: [:])
        await rl.update("p", headers: ["Retry-After": "30"], status: 429)
        let blocked = await rl.secondsBlocked("p")
        XCTAssertGreaterThan(blocked, 25)
    }
}
