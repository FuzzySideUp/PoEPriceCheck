import Foundation

/// One searchable condition shown in the panel with an on/off toggle.
public struct StatFilter: Identifiable, Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case stat(String)        // trade stat id, goes in query.stats
        case equipment(String)   // equipment_filters key: es, ar, ev, dps, pdps, edps, spirit, block
    }
    public var id: String { label }
    public var label: String          // "+# total maximum Life"
    public var target: Target
    public var rolled: Double         // value on the item (summed for pseudo)
    public var weight: Int            // higher = more important to value
    public var enabled: Bool
    public var sources: [String]      // tooltip lines that fed this filter
    /// Stats without a number, such as anoints ("Allocates Flip the Script"): searched by id alone.
    public var valueless = false

    public func minValue(margin: Double) -> Double {
        // Small whole numbers (+2 skill levels, 3 charm slots) aren't shaved: 4 -> 3.6 would mean 3.
        if rolled == rolled.rounded(), abs(rolled) < 10 { return rolled }
        let v = rolled * (1 - margin)
        return abs(rolled) >= 10 ? floor(v) : (v * 100).rounded(.down) / 100
    }

    public func display(margin: Double) -> String {
        if valueless { return label }
        let v = Self.fmt(minValue(margin: margin)) + "+"
        // "Adds # to # Fire Damage" is searched by its average.
        if label.contains("# to #") {
            return label.replacingOccurrences(of: "# to #", with: "avg \(v)")
        }
        return label.replacingOccurrences(of: "#", with: v)
    }

    public static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

public struct RareSearch: Sendable, Equatable {
    public var filters: [StatFilter]
    public var margin: Double
    public var category: String?
    public var baseType: String?
    public var useBaseType: Bool
    public var itemLevel: Int?
    public var useItemLevel: Bool
    public var nonCorruptedOnly: Bool
    public var status: String
    /// Unidentified items: search unidentified listings of at least this tier (PoE 2; PoE 1 has no tiers).
    public var unidentifiedTier: Int?
    /// PoE 1: minimum linked sockets (5L/6L), picked in the panel since OCR can't see sockets.
    public var links: Int?
    public var game: Game = .poe2
    /// Human-readable notes about what auto-relaxation changed.
    public var relaxNotes: [String] = []

    public var itemLevelFloor: Int? { itemLevel.map { max(1, $0 - 10) } }

    public func queryJSON() -> [String: Any] {
        var statFilters: [[String: Any]] = []
        var propertyGroups: [String: [String: Any]] = [:]
        for f in filters where f.enabled {
            switch f.target {
            case let .stat(id) where f.valueless: statFilters.append(["id": id])
            case let .stat(id): statFilters.append(["id": id, "value": ["min": f.minValue(margin: margin)]])
            case let .equipment(key): propertyGroups[game.propertyFilterGroup(key), default: [:]][key] = ["min": f.minValue(margin: margin)]
            }
        }
        var typeFilters: [String: Any] = ["rarity": ["option": "nonunique"]]
        if let c = category, !useBaseType { typeFilters["category"] = ["option": c] }
        if useItemLevel, let floor = itemLevelFloor { typeFilters["ilvl"] = ["min": floor] }
        var filters: [String: Any] = ["type_filters": ["filters": typeFilters]]
        for (group, values) in propertyGroups { filters[group] = ["filters": values] }
        if let links { filters["socket_filters"] = ["filters": ["links": ["min": links]]] }
        var misc: [String: Any] = [:]
        if nonCorruptedOnly { misc["corrupted"] = ["option": "false"] }
        if let tier = unidentifiedTier {
            misc["identified"] = ["option": "false"]
            if game == .poe2 { misc["unidentified_tier"] = ["min": tier] }
        }
        if !misc.isEmpty { filters["misc_filters"] = ["filters": misc] }

        var query: [String: Any] = [
            "status": ["option": status],
            "stats": [["type": "and", "filters": statFilters]],
            "filters": filters,
        ]
        if (useBaseType || category == nil), let b = baseType { query["type"] = b }
        return ["query": query, "sort": ["price": "asc"]]
    }

    /// Next looser search, or nil when nothing is left to relax.
    public func relaxed() -> RareSearch? {
        var s = self
        if s.useItemLevel, s.itemLevel != nil {
            s.useItemLevel = false
            s.relaxNotes.append("dropped item level floor")
            return s
        }
        if s.useBaseType, s.category != nil {
            s.useBaseType = false
            s.relaxNotes.append("any \(s.category!) base")
            return s
        }
        // A wider margin only helps filters with a value (not anoints).
        let hasValues = s.filters.contains { $0.enabled && !$0.valueless }
        if hasValues, s.margin < 0.2 {
            s.margin = 0.2
            s.relaxNotes.append("margin widened to 20%")
            return s
        }
        let enabled = s.filters.indices.filter { s.filters[$0].enabled }
        if enabled.count > 1 {
            // Least important = lowest weight; among ties the last one listed.
            let idx = enabled.min { a, b in
                s.filters[a].weight != s.filters[b].weight ? s.filters[a].weight < s.filters[b].weight : a > b
            }!
            s.filters[idx].enabled = false
            s.relaxNotes.append("dropped \(s.filters[idx].label)")
            return s
        }
        if hasValues, s.margin < 0.35 {
            s.margin = 0.35
            s.relaxNotes.append("margin widened to 35%")
            return s
        }
        return nil
    }
}

/// Builds the fuzzy rare search: value-driving stats only, pseudo totals, min-only values.
public struct RareQueryBuilder {
    let data: GameData
    public var margin: Double
    public var maxEnabled: Int
    public var status: String

    public init(data: GameData, margin: Double = 0.1, maxEnabled: Int = 6, status: String = "available") {
        self.data = data
        self.margin = margin
        self.maxEnabled = maxEnabled
        self.status = status
    }

    private enum Pseudo: String {
        case life = "pseudo.pseudo_total_life"
        case mana = "pseudo.pseudo_total_mana"
        case es = "pseudo.pseudo_total_energy_shield"
        case eleRes = "pseudo.pseudo_total_elemental_resistance"
        case chaosRes = "pseudo.pseudo_total_chaos_resistance"
        case str = "pseudo.pseudo_total_strength"
        case dex = "pseudo.pseudo_total_dexterity"
        case int = "pseudo.pseudo_total_intelligence"
    }

    public func build(_ item: ParsedItem) -> RareSearch {
        let cat = item.category ?? ""
        let isArmour = cat.hasPrefix("armour")
        let isWeapon = cat.hasPrefix("weapon")
        let preferLocal = isArmour || isWeapon

        var pseudo: [Pseudo: (Double, [String])] = [:]
        func add(_ p: Pseudo, _ v: Double, _ src: String) {
            let cur = pseudo[p] ?? (0, [])
            pseudo[p] = (cur.0 + v, cur.1 + [src])
        }
        var filters: [StatFilter] = []

        for mod in item.mods {
            guard let match = data.matchStat(mod.text),
                  let stat = data.pick(match.stats, kind: mod.kind, preferLocal: preferLocal) else { continue }
            let key = TextUtil.templateKey(stat.text.replacingOccurrences(of: " (Local)", with: ""))
            let values = match.values
            let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)

            // Local defences / weapon damage are covered by the item's property filters.
            if Self.coveredByProperties(key, isArmour: isArmour, isWeapon: isWeapon) { continue }

            // Pseudo totals
            if key == "# to maximum life" { add(.life, avg, mod.text); continue }
            if key == "# to maximum mana" { add(.mana, avg, mod.text); continue }
            if key == "# to maximum energy shield", !stat.isLocal { add(.es, avg, mod.text); continue }
            if key.contains("resistance"), !key.contains("maximum"), !key.contains("penetrat"), key.hasPrefix("#% to") {
                if key.contains("all elemental") { add(.eleRes, avg * 3, mod.text); continue }
                var counted = false
                for el in ["fire", "cold", "lightning"] where key.contains(el) { add(.eleRes, values.first ?? avg, mod.text); counted = true }
                if key.contains("chaos") { add(.chaosRes, values.first ?? avg, mod.text); counted = true }
                if counted { continue }
            }
            if key.hasPrefix("# to ") && (key.contains("strength") || key.contains("dexterity") || key.contains("intelligence") || key.contains("all attributes")) {
                let v = values.first ?? avg
                let all = key.contains("all attributes")
                if all || key.contains("strength") { add(.str, v, mod.text) }
                if all || key.contains("dexterity") { add(.dex, v, mod.text) }
                if all || key.contains("intelligence") { add(.int, v, mod.text) }
                continue
            }

            // Anoints ("Allocates Flip the Script") carry no number: the passive is the whole stat, and it's
            // usually what the item is worth.
            if values.isEmpty, key.hasPrefix("allocates ") {
                // On amulets it's an enchant (anoint) even when OCR missed the colour.
                let anoint = cat == "accessory.amulet" ? data.pick(match.stats, kind: .enchant, preferLocal: false) ?? stat : stat
                filters.append(StatFilter(label: anoint.text, target: .stat(anoint.id), rolled: 0, weight: 8, enabled: false,
                                          sources: [mod.text], valueless: true))
                continue
            }
            guard avg > 0 else { continue }
            let w = Self.weight(key, isWeapon: isWeapon, local: stat.isLocal)
            filters.append(StatFilter(label: stat.text.replacingOccurrences(of: " (Local)", with: ""),
                                      target: .stat(stat.id), rolled: avg, weight: w, enabled: false, sources: [mod.text]))
        }

        // PoE 1's pseudo totals count life from Strength and mana from Intelligence (1 per 2 points).
        if data.game == .poe1 {
            if let life = pseudo[.life], let str = pseudo[.str] { pseudo[.life] = (life.0 + (str.0 / 2).rounded(.down), life.1 + str.1) }
            if let mana = pseudo[.mana], let int = pseudo[.int] { pseudo[.mana] = (mana.0 + (int.0 / 2).rounded(.down), mana.1 + int.1) }
        }

        let pseudoMeta: [(Pseudo, Int)] = [(.life, 9), (.eleRes, 8), (.chaosRes, 6), (.es, 6), (.str, 4), (.dex, 4), (.int, 4), (.mana, 3)]
        for (p, w) in pseudoMeta {
            guard let (v, src) = pseudo[p], v > 0, let stat = data.pseudoStats[p.rawValue] else { continue }
            filters.append(StatFilter(label: stat.text, target: .stat(p.rawValue), rolled: v, weight: w, enabled: false, sources: src))
        }

        filters += propertyFilters(item, isArmour: isArmour, isWeapon: isWeapon)

        // Enable the most valuable ones.
        let order = filters.indices.sorted { filters[$0].weight > filters[$1].weight }
        for (rank, idx) in order.enumerated() where filters[idx].weight >= 5 && rank < maxEnabled {
            filters[idx].enabled = true
        }
        // Nothing valuable: still search on the best thing the item has so results resemble it.
        if !filters.contains(where: \.enabled), let best = order.first, filters[best].weight >= 2 {
            filters[best].enabled = true
        }
        filters.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.label < $1.label }

        return RareSearch(filters: filters, margin: margin, category: item.category, baseType: item.baseType,
                          useBaseType: item.category == nil, itemLevel: item.itemLevel, useItemLevel: item.itemLevel != nil,
                          nonCorruptedOnly: !item.corrupted, status: status,
                          unidentifiedTier: item.unidentified ? Int(item.properties["Unidentified Tier"] ?? "") ?? 1 : nil,
                          game: data.game)
    }

    /// Local defence and weapon damage mods are already reflected in the item's
    /// Armour/Evasion/ES and DPS properties, which are searched instead.
    static func coveredByProperties(_ key: String, isArmour: Bool, isWeapon: Bool) -> Bool {
        if isArmour {
            let local: Set<String> = [
                "# to maximum energy shield", "# to armour", "# to evasion rating",
                "#% increased energy shield", "#% increased armour", "#% increased evasion rating",
                "#% increased armour and evasion", "#% increased armour and energy shield",
                "#% increased evasion and energy shield", "#% increased armour evasion and energy shield",
            ]
            return local.contains(key)
        }
        if isWeapon {
            let local: Set<String> = [
                "adds # to # physical damage", "adds # to # fire damage", "adds # to # cold damage",
                "adds # to # lightning damage", "adds # to # chaos damage",
                "#% increased physical damage", "#% increased attack speed",
            ]
            return local.contains(key)
        }
        return false
    }

    /// How much a stat tends to drive price. >= 5 is searched by default.
    /// PoE 1 and PoE 2 word most stats differently ("Critical Strike" vs "Critical Hit"), so one table serves both.
    static func weight(_ key: String, isWeapon: Bool, local: Bool) -> Int {
        let rules: [(String, Int)] = [
            ("to level of all", 10), ("movement speed", 10), ("to spirit", 8),
            ("critical damage bonus", 6), ("critical hit chance", local ? 4 : 6),
            // PoE 1
            ("to all maximum resistances", 9), ("to level of socketed", 7), ("suppress spell damage", 8),
            ("critical strike multiplier", 6), ("critical strike chance", local ? 4 : 6),
            ("damage over time multiplier", 6), ("reservation efficiency", 6),
            ("increased spell damage", 6), ("gain #% of damage as extra", 6), ("damage as extra", 6),
            ("increased fire damage", 5), ("increased cold damage", 5), ("increased lightning damage", 5),
            ("increased chaos damage", 5), ("increased elemental damage", 5), ("increased physical damage", 5),
            ("increased projectile damage", 5), ("increased attack damage", 5), ("minion", 5),
            ("allies in your presence deal", 5),
            ("attack speed", 6), ("cast speed", 6), ("rarity of items", 5),
            ("increased maximum life", 5), ("increased maximum energy shield", 5), ("increased maximum mana", 3),
            ("to accuracy rating", 2), ("regeneration", 3), ("leech", 3), ("recoup", 3),
            ("on kill", 1), ("light radius", 1), ("stun", 1), ("thorns", 1), ("attribute requirements", 0),
            ("charm", 3), ("flask", 3), ("block", 3),
        ]
        for (pattern, w) in rules where key.contains(pattern) { return w }
        return 3
    }

    private func propertyFilters(_ item: ParsedItem, isArmour: Bool, isWeapon: Bool) -> [StatFilter] {
        var out: [StatFilter] = []
        func prop(_ names: [String]) -> String? {
            for n in names { if let v = item.properties.first(where: { TextUtil.normalize($0.key) == n })?.value { return v } }
            return nil
        }
        if isArmour {
            for (names, key, label) in [(["energy shield"], "es", "Energy Shield: #"),
                                        (["armour"], "ar", "Armour: #"),
                                        (["evasion rating"], "ev", "Evasion: #")] {
                if let v = prop(names).flatMap({ TextUtil.numbers(in: $0).first }), v > 0 {
                    out.append(StatFilter(label: label, target: .equipment(key), rolled: v, weight: 7, enabled: false, sources: []))
                }
            }
        }
        if let v = prop(["spirit"]).flatMap({ TextUtil.numbers(in: $0).first }), v > 0 {
            out.append(StatFilter(label: "Spirit: #", target: .equipment("spirit"), rolled: v, weight: 8, enabled: false, sources: []))
        }
        if isWeapon, let aps = prop(["attacks per second"]).flatMap({ TextUtil.numbers(in: $0).first }), aps > 0 {
            func avgDamage(_ s: String?) -> Double {
                guard let s else { return 0 }
                let n = TextUtil.numbers(in: s.replacingOccurrences(of: "-", with: " - ")).map(abs)
                var total = 0.0
                var i = 0
                while i + 1 < n.count { total += (n[i] + n[i + 1]) / 2; i += 2 }
                return total
            }
            let phys = avgDamage(prop(["physical damage"])) * aps
            var ele = avgDamage(prop(["elemental damage"]))
            if ele == 0 { ele = ["fire damage", "cold damage", "lightning damage"].map { avgDamage(prop([$0])) }.reduce(0, +) }
            ele *= aps
            let total = phys + ele + avgDamage(prop(["chaos damage"])) * aps
            if total > 0 {
                let physHeavy = phys / total >= 0.6, eleHeavy = ele / total >= 0.6
                out.append(StatFilter(label: "DPS: #", target: .equipment("dps"), rolled: total.rounded(),
                                      weight: physHeavy || eleHeavy ? 4 : 10, enabled: false, sources: []))
                if phys > 0 {
                    out.append(StatFilter(label: "Physical DPS: #", target: .equipment("pdps"), rolled: phys.rounded(),
                                          weight: physHeavy ? 10 : 4, enabled: false, sources: []))
                }
                if ele > 0 {
                    out.append(StatFilter(label: "Elemental DPS: #", target: .equipment("edps"), rolled: ele.rounded(),
                                          weight: eleHeavy ? 10 : 4, enabled: false, sources: []))
                }
            }
        }
        return out
    }
}
