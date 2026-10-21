import XCTest
@testable import PoECore

/// Hits poe.ninja and the trade API. Run with: POE_LIVE=1 swift test --filter LiveTests
final class LiveTests: XCTestCase {
    let ua = "PoEPriceCheck/0.1 (macOS; personal OCR price-check overlay; tests)"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POE_LIVE"] == "1", "set POE_LIVE=1 to run")
    }

    func testNinjaCurrencyAndUnique() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poepc-live")
        let ninja = NinjaClient(cacheDirectory: dir, userAgent: ua)
        let league = try await ninja.currentLeague()
        let snap = try await ninja.ensure(league: league)
        XCTAssertGreaterThan(snap.exaltedPerDivine, 1)
        let ex = await ninja.lookup(name: "Exalted Orb", baseType: nil, corrupted: false)
        XCTAssertNotNil(ex)
        let headhunter = await ninja.lookup(name: "Headhunter", baseType: "Heavy Belt", corrupted: false)
        XCTAssertNotNil(headhunter)
        print("LIVE league=\(league) ex=\(ex!.divine) div, HH=\(headhunter!.divine) div, ex/div=\(snap.exaltedPerDivine)")
    }

    func testPoE1NinjaAndTrade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poepc-live")
        let ninja = NinjaClient(cacheDirectory: dir, userAgent: ua, game: .poe1)
        let league = try await ninja.currentLeague()
        let snap = try await ninja.ensure(league: league)
        XCTAssertGreaterThan(snap.chaosPerDivine, 10)
        let chaosHit = await ninja.lookup(name: "Chaos Orb", baseType: nil, corrupted: false)
        let chaos = try XCTUnwrap(chaosHit)
        XCTAssertEqual(chaos.divine * snap.chaosPerDivine, 1, accuracy: 0.01)
        let coil = await ninja.lookup(name: "Lightning Coil", baseType: "Desert Brigandine", corrupted: false)
        let coil6 = await ninja.lookup(name: "Lightning Coil", baseType: "Desert Brigandine", corrupted: false, links: 6)
        XCTAssertNil(coil?.links)
        XCTAssertEqual(coil6?.links, 6)
        print("LIVE poe1 league=\(league) c/div=\(snap.chaosPerDivine) coil=\((coil?.divine ?? 0) * snap.chaosPerDivine)c 6L=\((coil6?.divine ?? 0) * snap.chaosPerDivine)c")

        var item = PoE1ParserTests().rareChest()
        item.corrupted = false
        let trade = TradeClient(userAgent: ua, game: .poe1)
        let leagues = try await trade.leagues()
        XCTAssertTrue(leagues.contains(league))
        let r = try await trade.price(RareQueryBuilder(data: TestData.poe1Data).build(item), league: league, autoRelax: true,
                                      currencyRates: snap.currencyById)
        print("LIVE poe1 rare total=\(r.total) relax=\(r.search?.relaxNotes ?? []) url=\(r.webURL)")
        for l in r.listings { print("  \(l.amount) \(l.currency) ≈ \(l.divine ?? -1) div") }
        XCTAssertGreaterThan(r.total, 0)
    }

    func testFuzzyRareSearch() async throws {
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
        """)
        lines[0].color = .rare; lines[1].color = .rare
        let item = TestData.parser.parse(lines)
        let search = RareQueryBuilder(data: TestData.gameData).build(item)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("poepc-live")
        let ninja = NinjaClient(cacheDirectory: dir, userAgent: ua)
        let league = try await ninja.currentLeague()
        let rates = try await ninja.ensure(league: league).currencyById
        let trade = TradeClient(userAgent: ua)
        let r = try await trade.price(search, league: league, autoRelax: true, currencyRates: rates)
        print("LIVE total=\(r.total) relax=\(r.search?.relaxNotes ?? []) url=\(r.webURL)")
        for f in r.search?.filters ?? [] where f.enabled { print("  used: \(f.display(margin: r.search!.margin))") }
        for l in r.listings { print("  \(l.amount) \(l.currency) ≈ \(l.divine ?? -1) div ilvl \(l.itemLevel ?? 0)") }
        XCTAssertGreaterThan(r.total, 0)
        XCTAssertFalse(r.listings.isEmpty)
    }
}
