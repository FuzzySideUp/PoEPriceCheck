import Foundation

public struct TradeStat: Codable, Sendable, Hashable {
    public let id: String      // e.g. "explicit.stat_3299347043"
    public let text: String    // e.g. "# to maximum Life"
    public let type: String    // explicit / implicit / rune / pseudo ...

    public var isLocal: Bool { text.contains("(Local)") }
    /// Numeric hash shared by the same stat across explicit/implicit/etc.
    public var hash: String { id.split(separator: ".").last.map(String.init) ?? id }
}

public struct StatMatch: Sendable, Equatable {
    public let stat: TradeStat
    public let values: [Double]
    public let score: Double
}

/// Static game/trade data: base types, unique names, trade stat templates.
public final class GameData: @unchecked Sendable {
    public let game: Game
    public let baseCategories: [String: String]
    public let uniqueBases: [String: [String]]      // unique name -> base types
    public let gemNames: Set<String>
    public let currencyNames: Set<String>
    public let pseudoStats: [String: TradeStat]     // id -> stat

    private var statsByKey: [String: [TradeStat]] = [:]
    private var keysByLength: [Int: [(key: String, hashes: Int)]] = [:]
    private let baseNamesSorted: [(normalized: String, name: String)]
    private let normalizedBases: [String: String]   // normalized -> real name
    private let normalizedUniques: [String: String]

    public init(directory: URL, game: Game = .poe2) throws {
        self.game = game
        let dec = JSONDecoder()
        baseCategories = try dec.decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("base_items.json")))

        struct ItemsFile: Decodable {
            struct Group: Decodable {
                struct Entry: Decodable { let type: String; let name: String?; let flags: [String: Bool]? }
                let id: String; let entries: [Entry]
            }
            let result: [Group]
        }
        let items = try dec.decode(ItemsFile.self, from: Data(contentsOf: directory.appendingPathComponent("items.json")))
        var uniques: [String: [String]] = [:]
        var gems = Set<String>()
        var currency = Set<String>()
        var allTypes = Set(baseCategories.keys)
        for g in items.result {
            for e in g.entries {
                if let n = e.name, e.flags?["unique"] == true { uniques[n, default: []].append(e.type) }
                if g.id == "gem" { gems.insert(e.type) }
                if g.id == "currency" { currency.insert(e.type) }
                // PoE 1: divination cards and fragments/scarabs are priced like currency (poe.ninja exchange).
                if game == .poe1, e.name == nil, g.id == "card" || (g.id == "map" && !e.type.hasSuffix(" Map")) {
                    currency.insert(e.type)
                }
                if e.name == nil { allTypes.insert(e.type) }
            }
        }
        uniqueBases = uniques
        gemNames = gems
        currencyNames = currency
        baseNamesSorted = allTypes.sorted { $0.count > $1.count }.map { (" " + TextUtil.normalize($0) + " ", $0) }
        normalizedBases = Dictionary(allTypes.map { (TextUtil.normalize($0), $0) }, uniquingKeysWith: { a, _ in a })
        normalizedUniques = Dictionary(uniques.keys.map { (TextUtil.normalize($0), $0) }, uniquingKeysWith: { a, _ in a })

        struct StatsFile: Decodable {
            struct Group: Decodable { let id: String; let entries: [TradeStat] }
            let result: [Group]
        }
        let stats = try dec.decode(StatsFile.self, from: Data(contentsOf: directory.appendingPathComponent("stats.json")))
        var pseudo: [String: TradeStat] = [:]
        for g in stats.result {
            for s in g.entries {
                if g.id == "pseudo" { pseudo[s.id] = s; continue }
                let text = s.text.replacingOccurrences(of: "(Local)", with: "")
                var keys = [TextUtil.templateKey(text)]
                // Multi-line templates: also index the first line on its own.
                if let first = text.components(separatedBy: "\n").first, text.contains("\n") {
                    keys.append(TextUtil.templateKey(first))
                }
                for key in keys where !key.isEmpty { statsByKey[key, default: []].append(s) }
            }
        }
        pseudoStats = pseudo
        for k in statsByKey.keys { keysByLength[k.count, default: []].append((k, k.filter { $0 == "#" }.count)) }
    }

    public func category(forBase base: String) -> String? { baseCategories[base] }

    // MARK: - Names

    /// Exact or fuzzy base type match for a whole line.
    public func matchBase(_ line: String, minScore: Double = 0.86) -> String? {
        let n = TextUtil.normalize(line)
        if let exact = normalizedBases[n] { return exact }
        return bestFuzzy(n, in: normalizedBases, minScore: minScore)
    }

    /// Finds a base type contained in a magic item's name ("Hale Bound Sandals of the Penguin").
    public func baseContained(in line: String) -> String? {
        let n = " " + TextUtil.normalize(line) + " "
        for b in baseNamesSorted where n.contains(b.normalized) { return b.name }
        return nil
    }

    public func matchUnique(_ line: String, minScore: Double = 0.86) -> String? {
        let n = TextUtil.normalize(line)
        if let exact = normalizedUniques[n] { return exact }
        return bestFuzzy(n, in: normalizedUniques, minScore: minScore)
    }

    private func bestFuzzy(_ n: String, in dict: [String: String], minScore: Double) -> String? {
        // Also try common OCR confusions ("rn" read for "m", "0" for "o", "1" for "l").
        var variants = [n]
        let fixed = n.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l")
        if fixed != n { variants.append(fixed) }
        var best: (String, Double)?
        for v in variants {
            if let exact = dict[v] { return exact }
            for (k, name) in dict where abs(k.count - v.count) <= max(3, v.count / 5) {
                let s = TextUtil.similarity(v, k)
                if s >= minScore, s > (best?.1 ?? 0) { best = (name, s) }
            }
        }
        return best?.0
    }

    // MARK: - Stats

    /// Maps a tooltip mod line to trade stats. Returns candidates of all types sharing the template;
    /// the caller picks the type (explicit/implicit/...).
    public func matchStat(_ line: String) -> (stats: [TradeStat], values: [Double], score: Double)? {
        let clean = TextUtil.clean(line)
        let values = TextUtil.numbers(in: clean)
        let key = TextUtil.templateKey(clean)
        if let hit = statsByKey[key] { return (hit, values, 1) }

        // "reduced" lines are stored as the "increased" stat with a negative value.
        for (a, b) in [("reduced", "increased"), ("less", "more"), ("fewer", "additional")] where key.contains(a) {
            let swapped = key.replacingOccurrences(of: a, with: b)
            if let hit = statsByKey[swapped] { return (hit, values.map { -$0 }, 0.99) }
        }

        // Fuzzy: OCR noise in words. Compare only keys of similar length with the same number of '#'.
        let hashes = key.filter { $0 == "#" }.count
        var best: (String, Double)?
        let tol = max(3, key.count / 6)
        for len in (key.count - tol)...(key.count + tol) {
            for k in keysByLength[len] ?? [] where k.hashes == hashes {
                let s = TextUtil.similarity(key, k.key)
                if s > (best?.1 ?? 0.84) { best = (k.key, s) }
            }
        }
        if let (k, s) = best, let hit = statsByKey[k] { return (hit, values, s) }
        return nil
    }

    /// Picks one stat among same-template candidates.
    public func pick(_ candidates: [TradeStat], kind: ModKind, preferLocal: Bool) -> TradeStat? {
        let typeOrder: [String]
        switch kind {
        case .explicit: typeOrder = ["explicit", "desecrated", "fractured", "implicit", "crafted", "rune", "enchant"]
        case .implicit: typeOrder = ["implicit", "explicit"]
        case .rune: typeOrder = ["augment", "rune", "enchant", "explicit"]
        case .enchant: typeOrder = ["enchant", "augment", "rune", "implicit", "explicit"]
        case .fractured: typeOrder = ["fractured", "explicit"]
        case .desecrated: typeOrder = ["desecrated", "explicit"]
        case .crafted: typeOrder = ["crafted", "explicit"]
        }
        for t in typeOrder {
            let ofType = candidates.filter { $0.type == t }
            if ofType.isEmpty { continue }
            if let s = ofType.first(where: { $0.isLocal == preferLocal }) { return s }
            return ofType.first
        }
        return candidates.first
    }
}
