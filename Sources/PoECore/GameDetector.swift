import Foundation

/// Decides per check whether the tooltip on screen is from PoE 1 or PoE 2, using the OCR already done:
/// GeForce NOW streams both games in the same window, so there's nothing else to go on.
///
/// In order: an area-overlay league ("Allflame League") that only one game has, a window title naming the
/// game (when GeForce NOW or the browser shows one), then tooltip wording that
/// only one game uses, then which game's data knows the item better. Items both games share (Divine Orb)
/// keep the last game.
public struct GameDetector {
    public struct Decision: Sendable {
        public let game: Game
        public let item: ParsedItem
        public let reason: String
        /// The league named on screen, when that settled it.
        public let league: String?
    }

    let parsers: [Game: ItemParser]

    public init(data: [Game: GameData]) {
        parsers = data.mapValues { ItemParser(data: $0) }
    }

    public func decide(tooltip: [OCRLine], allLines: [OCRLine], leagues: [Game: [String]], last: Game,
                       windowTitle: String? = nil) -> Decision {
        var items: [Game: ParsedItem] = [:]
        for (g, p) in parsers { items[g] = p.parse(tooltip) }
        func decision(_ g: Game, _ reason: String, league: String? = nil) -> Decision {
            Decision(game: g, item: items[g] ?? items[last] ?? ParsedItem(), reason: reason, league: league)
        }
        guard items.count > 1 else { return decision(items.keys.first ?? last, "only one game loaded") }

        // 1. League in the area overlay. "Standard" and "Hardcore" exist in both games and say nothing.
        let named = Game.allCases.compactMap { g in TooltipReader.detectLeague(in: allLines, known: leagues[g] ?? []).map { (g, $0) } }
        if named.count == 1, let (g, league) = named.first { return decision(g, "league \"\(league)\" on screen", league: league) }

        // 2. "Path of Exile 2 on GeForce NOW" style window titles.
        if let t = windowTitle, let g = Self.game(inTitle: t) { return decision(g, "window title \"\(t)\"") }

        // 3. Wording only one game uses.
        if let (g, why) = Self.wordingSignal(tooltip) { return decision(g, why) }

        // 4. Which game's data knows the item.
        var scores: [Game: Double] = [:]
        for (g, item) in items { scores[g] = Self.confidence(item, data: parsers[g]!.data, raw: tooltip.map(\.text)) }
        let ranked = scores.sorted { $0.value > $1.value }
        if ranked.count >= 2, ranked[0].value - ranked[1].value >= 0.5 {
            let s = ranked.map { "\($0.key.rawValue) \(String(format: "%.1f", $0.value))" }.joined(separator: ", ")
            return decision(ranked[0].key, "item known better (\(s))")
        }
        return decision(last, "item in both games; kept last game")
    }

    public static func game(inTitle title: String) -> Game? {
        let t = title.lowercased()
        if t.contains("path of exile 2") || t.contains("path of exile ii") || t.contains("poe2") { return .poe2 }
        if t.contains("path of exile") { return .poe1 }
        return nil
    }

    /// PoE 2 writes "Requires: Level 52" and shows an item class line ("RING", "BODY ARMOUR") under the name;
    /// PoE 1 writes "Requires Level 52". Class names both games show for weapons ("BOW") don't count.
    static func wordingSignal(_ lines: [OCRLine]) -> (Game, String)? {
        let poe2Only = ItemParser.poe2ItemClasses.subtracting(ItemParser.poe1ItemClasses)
        for (i, l) in lines.enumerated() {
            let lower = TextUtil.clean(l.text).lowercased()
            if let r = lower.range(of: "requires") {
                let rest = lower[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":") { return (.poe2, "\"Requires:\" line") }
                if rest.hasPrefix("level") { return (.poe1, "\"Requires Level\" line") }
            }
            if i >= 1, i <= 3, poe2Only.contains(TextUtil.normalize(l.text)) {
                return (.poe2, "item class line \"\(TextUtil.clean(l.text))\"")
            }
        }
        return nil
    }

    /// How well a parse matches that game's data: exact names score higher than fuzzy ones.
    static func confidence(_ item: ParsedItem, data: GameData, raw: [String]) -> Double {
        let head = Array(raw.prefix(3)).map(TextUtil.normalize)
        func match(_ name: String?, contained: Bool = false) -> Double {
            guard let k = name.map(TextUtil.normalize), !k.isEmpty else { return 0 }
            var best = 0.0
            for h in head {
                if contained, (" " + h + " ").contains(" " + k + " ") { return 1 }
                best = max(best, TextUtil.similarity(h, k))
            }
            return best
        }
        func knownBase(_ b: String?) -> Bool { b.flatMap { data.category(forBase: $0) } != nil }
        var s: Double
        switch item.rarity {
        case .unknown:
            return 0
        case .unique:
            s = (item.name.map { data.uniqueBases[$0] != nil } ?? false ? 2 * match(item.name) : 0)
                + (knownBase(item.baseType) ? match(item.baseType) : 0)
        case .rare, .normal:
            s = knownBase(item.baseType) ? 2 * match(item.baseType) : 0
        case .magic:
            s = knownBase(item.baseType) ? 2 * match(item.baseType, contained: true) : 0
        case .currency, .gem:
            s = item.name.flatMap { data.matchBase($0) }.map { match($0) } ?? 0
        }
        return s + 0.05 * Double(item.mods.count)
    }
}
