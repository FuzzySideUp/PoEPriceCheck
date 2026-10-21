import Foundation

/// Which Path of Exile the overlay prices: trade API, poe.ninja endpoints, bundled data and currency units.
public enum Game: String, Codable, CaseIterable, Sendable {
    case poe1, poe2

    public var title: String { self == .poe1 ? "Path of Exile 1" : "Path of Exile 2" }

    /// Folder under Data/ (and the app's Resources) with stats.json, items.json and base_items.json.
    public var dataFolder: String { rawValue }

    /// Trade API root: api/trade (PoE 1) or api/trade2 (PoE 2).
    var tradeAPI: String {
        self == .poe1 ? "https://www.pathofexile.com/api/trade" : "https://www.pathofexile.com/api/trade2"
    }

    /// Realm segment in search URLs and the fetch `realm` parameter. PoE 1 PC needs none.
    var realm: String? { self == .poe1 ? nil : "poe2" }

    /// Realm value in /data/leagues.
    var leagueRealm: String { self == .poe1 ? "pc" : "poe2" }

    func searchURL(league: String) -> URL {
        let l = league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? league
        return URL(string: "\(tradeAPI)/search/\(realm.map { "\($0)/" } ?? "")\(l)")!
    }

    func webURL(league: String, queryId: String) -> URL {
        let l = league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? league
        let site = self == .poe1 ? "trade" : "trade2"
        return URL(string: "https://www.pathofexile.com/\(site)/search/\(realm.map { "\($0)/" } ?? "")\(l)/\(queryId)")!
    }

    /// poe.ninja economy root.
    var ninjaBase: String { "https://poe.ninja/\(rawValue)" }

    /// poe.ninja exchange overview types (currency-like items).
    var ninjaExchangeTypes: [String] {
        switch self {
        case .poe1:
            return ["Currency", "Fragment", "Scarab", "Fossil", "Resonator", "Essence", "DivinationCard", "Oil", "Omen",
                    "DeliriumOrb", "Artifact", "Tattoo", "Runegraft", "AllflameEmber", "Astrolabe", "DjinnCoin"]
        case .poe2:
            return ["Currency", "Fragments", "Abyss", "UncutGems", "LineageSupportGems", "Essences", "SoulCores", "Idols",
                    "Runes", "Ritual", "Expedition", "Delirium", "Breach", "Verisium"]
        }
    }

    /// poe.ninja stash overview types (uniques and other per-item listings).
    var ninjaStashTypes: [String] {
        switch self {
        case .poe1:
            return ["UniqueWeapon", "UniqueArmour", "UniqueAccessory", "UniqueFlask", "UniqueJewel", "UniqueMap",
                    "UniqueRelic", "UniqueTincture", "Invitation", "Vial", "Wombgift"]
        case .poe2:
            return ["UniqueWeapons", "UniqueArmours", "UniqueAccessories", "UniqueFlasks", "UniqueCharms",
                    "UniqueJewels", "UniqueSanctumRelics", "UniqueTablets", "PrecursorTablets"]
        }
    }

    /// The everyday currency below a Divine Orb: Chaos Orbs in PoE 1, Exalted Orbs in PoE 2.
    public var smallCurrency: String { self == .poe1 ? "chaos" : "exalted" }
    public var smallCurrencyShort: String { self == .poe1 ? "c" : "ex" }

    /// Equipment property filters live in one group in PoE 2 and in armour/weapon groups in PoE 1.
    func propertyFilterGroup(_ key: String) -> String {
        guard self == .poe1 else { return "equipment_filters" }
        return ["dps", "pdps", "edps", "aps", "crit", "damage"].contains(key) ? "weapon_filters" : "armour_filters"
    }
}
