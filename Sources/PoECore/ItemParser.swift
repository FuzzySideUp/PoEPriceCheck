import CoreGraphics
import Foundation

/// Turns OCR'd tooltip lines (top to bottom) into a ParsedItem.
public struct ItemParser {
    let data: GameData

    public init(data: GameData) { self.data = data }

    /// Lines whose text is exactly this act as block separators (used by text-only tests).
    public static let separator = "--------"

    /// Item class line shown under the name in PoE 2 tooltips.
    static let poe2ItemClasses: Set<String> = [
        "ring", "amulet", "belt", "jewel", "body armour", "helmet", "gloves", "boots", "shield", "buckler", "focus",
        "quiver", "sceptre", "wand", "staff", "quarterstaff", "warstaff", "bow", "crossbow", "spear", "flail", "dagger",
        "claw", "talisman", "one hand mace", "two hand mace", "one hand sword", "two hand sword", "one hand axe",
        "two hand axe", "one handed mace", "two handed mace", "one handed sword", "two handed sword", "one handed axe",
        "two handed axe", "life flask", "mana flask", "charm", "waystone", "tablet", "relic", "fishing rod",
        "skill gem", "support gem", "meta gem", "stackable currency", "omen", "rune", "soul core", "idol", "map fragment",
    ]

    /// PoE 1 has no item class line; only weapons show their class ("Two Handed Sword") above the damage.
    static let poe1ItemClasses: Set<String> = [
        "bow", "claw", "dagger", "rune dagger", "staff", "warstaff", "wand", "sceptre", "fishing rod",
        "one handed sword", "thrusting one handed sword", "two handed sword", "one handed axe", "two handed axe",
        "one handed mace", "two handed mace", "abyss",
    ]

    var itemClasses: Set<String> { data.game == .poe1 ? Self.poe1ItemClasses : Self.poe2ItemClasses }

    /// PoE 1 lines that carry no price information.
    private static let poe1Ignored: Set<String> = [
        "mirrored", "split", "synthesised item", "fractured item", "shaper item", "elder item", "crusader item",
        "hunter item", "redeemer item", "warlord item", "searing exarch item", "eater of worlds item", "foulborn",
    ]

    /// "VICTORY SMASHER" -> "Victory Smasher" (PoE 2 renders tooltips in small caps).
    static func titleCase(_ s: String) -> String {
        // Small caps OCR as mostly-uppercase, sometimes with stray lowercase ("OBLIVION SpLInTER").
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty, Double(letters.filter(\.isUppercase).count) / Double(letters.count) >= 0.6 else { return s }
        let small: Set<String> = ["of", "the", "and", "a", "an", "in", "to", "for"]
        return s.lowercased().split(separator: " ").enumerated().map { i, w in
            let word = String(w)
            return i > 0 && small.contains(word) ? word : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static let knownProperties: Set<String> = [
        "armour", "evasion rating", "energy shield", "physical damage", "elemental damage",
        "fire damage", "cold damage", "lightning damage", "chaos damage", "critical hit chance",
        "attacks per second", "reload time", "spirit", "block chance", "chance to block",
        "quality", "level", "stack size", "item level", "waystone tier", "lasts", "consumes",
        "currently has", "limit", "radius", "cost", "cast time", "requires", "runic ward", "ward",
        "item quantity", "item rarity", "monster pack size", "revives available", "area level",
    ]

    public func parse(_ input: [OCRLine]) -> ParsedItem {
        var item = ParsedItem()
        let blocks = Self.blocks(from: input)
        item.rawLines = input.map(\.text)
        guard let header = blocks.first, !header.isEmpty else { return item }

        // Header: the first block (name/base). Guard against a merged header+body block.
        var headerLines = Array(header.prefix(3))
        var body = Array(blocks.dropFirst())
        // A "Label: value" line is never part of the name: PoE 1 puts "Stack Size: 1/5" close under the name.
        let split = header.indices.dropFirst().first { header[$0].text.contains(":") } ?? min(header.count, header.count > 3 ? 2 : 3)
        if split < header.count {
            headerLines = Array(header.prefix(split))
            body.insert(Array(header.dropFirst(split)), at: 0)
        }
        parseHeader(headerLines, into: &item)

        // Body
        var modBlocks: [[ModLine]] = []
        for block in body {
            var mods: [ModLine] = []
            var i = 0
            while i < block.count {
                let line = block[i]
                let text = Self.stripRollRanges(TextUtil.clean(line.text))
                i += 1
                if text.isEmpty || text == Self.separator { continue }
                if itemClasses.contains(TextUtil.normalize(text)) { continue }   // "RING", "BODY ARMOUR"…
                if parseSpecial(text, into: &item) { continue }
                if item.rarity == .unique, line.color == .unique { continue }        // flavour text
                if item.rarity == .currency || item.rarity == .gem {
                    if let (label, value) = Self.property(text) { item.properties[label] = value }
                    continue
                }
                if let (label, value) = Self.property(text) {
                    item.properties[label] = value
                    continue
                }
                if let mod = modLine(text, color: line.color) {
                    mods.append(mod)
                    continue
                }
                // Two-line mods (same colour, and the next line isn't a mod on its own)
                if i < block.count, block[i].color == line.color, data.matchStat(block[i].text) == nil {
                    let joined = text + "\n" + Self.stripRollRanges(TextUtil.clean(block[i].text))
                    if let mod = modLine(joined, color: line.color) {
                        mods.append(mod)
                        i += 1
                        continue
                    }
                }
            }
            if !mods.isEmpty { modBlocks.append(mods) }
        }

        // PoE 1 crafted mods and enchants share a colour: a block of nothing but those is the enchant block.
        if data.game == .poe1 {
            for idx in modBlocks.indices where modBlocks[idx].allSatisfy({ $0.kind == .crafted }) {
                modBlocks[idx] = modBlocks[idx].map { var m = $0; m.kind = .enchant; return m }
            }
        }

        // When explicit-coloured mods come in two blocks, the first one is the implicit block.
        // (PoE 1 explicit blocks can end with a crafted mod.)
        let plainBlocks = modBlocks.indices.filter { idx in
            modBlocks[idx].allSatisfy { $0.kind == .explicit || (data.game == .poe1 && $0.kind == .crafted) }
                && modBlocks[idx].contains { $0.kind == .explicit }
        }
        if plainBlocks.count >= 2 {
            let first = plainBlocks[0]
            modBlocks[first] = modBlocks[first].map { var m = $0; if m.kind == .explicit { m.kind = .implicit }; return m }
        }
        item.mods = modBlocks.flatMap { $0 }

        if let base = item.baseType { item.category = data.category(forBase: base) }
        return item
    }

    // MARK: - Header

    private func parseHeader(_ lines: [OCRLine], into item: inout ParsedItem) {
        let texts = lines.map { TextUtil.clean($0.text) }.filter { !$0.isEmpty && $0 != Self.separator }
        guard let first = texts.first else { return }
        // A mod line as the "name" means the real header was cut off or missed.
        if data.matchStat(first) != nil, TextUtil.numbers(in: first).count > 0 {
            item.rarity = .unknown
            item.name = Self.titleCase(first)
            return
        }
        let colorRarity = Self.rarity(fromColors: lines.map(\.color))

        var rarity = colorRarity
        if rarity == .unknown {
            if texts.count >= 2, data.matchUnique(first) != nil, data.matchBase(texts[1]) != nil { rarity = .unique }
            else if texts.count >= 2, data.matchBase(texts[1]) != nil { rarity = .rare }
            else if let b = data.matchBase(first), data.currencyNames.contains(b) { rarity = .currency }
            else if let b = data.matchBase(first), data.gemNames.contains(b) { rarity = .gem }
            else if data.matchBase(first) != nil { rarity = .normal }
            else if data.baseContained(in: first) != nil { rarity = .magic }
        }
        // Known currency/gem names win over a white/grey reading (currency headers are a pale tan).
        if rarity == .normal || rarity == .unknown, texts.count == 1, let b = data.matchBase(first) {
            if data.currencyNames.contains(b) { rarity = .currency }
            else if data.gemNames.contains(b) { rarity = .gem }
        }
        // PoE 2 skill tooltips: name, then "Spell" and the tags, in mixed colours.
        if rarity != .rare, rarity != .unique, let b = data.matchBase(first), data.gemNames.contains(b),
           texts.count == 1 || data.matchBase(texts[1]).flatMap({ data.category(forBase: $0) }) == nil {
            rarity = .gem
        }
        // Two-line header whose second line is an equipment base: rare or unique whatever the colour said
        // (dimmed/semi-transparent tooltips can sample as currency or grey).
        if rarity != .rare, rarity != .unique, texts.count >= 2, let b = data.matchBase(texts[1]),
           let cat = data.category(forBase: b), !cat.hasPrefix("gem") {
            rarity = data.matchUnique(first) != nil ? .unique : .rare
        }
        // A "rare/unique" header with a single line is almost always something else.
        if (rarity == .rare || rarity == .unique), texts.count == 1 {
            rarity = data.baseContained(in: first) != nil ? .magic : rarity
        }
        item.rarity = rarity

        switch rarity {
        case .unique:
            item.name = data.matchUnique(first) ?? Self.titleCase(first)
            if texts.count >= 2 { item.baseType = data.matchBase(texts[1]) ?? Self.titleCase(texts[1]) }
            // Name misread but base read fine: pick among the few uniques on that base.
            if data.matchUnique(first) == nil, let base = item.baseType {
                let norm = TextUtil.normalize(first)
                let best = data.uniqueBases.filter { $0.value.contains(base) }.keys
                    .map { ($0, TextUtil.similarity(norm, TextUtil.normalize($0))) }.max { $0.1 < $1.1 }
                if let (name, score) = best, score >= 0.6 { item.name = name }
            }
            if item.baseType == nil, let n = item.name, let bases = data.uniqueBases[n], bases.count == 1 {
                item.baseType = bases[0]
            }
        case .rare:
            item.name = Self.titleCase(first)
            if texts.count >= 2 { item.baseType = data.matchBase(texts[1]) ?? data.baseContained(in: texts[1]) ?? Self.titleCase(texts[1]) }
        case .magic:
            item.name = Self.titleCase(first)
            item.baseType = data.baseContained(in: first) ?? data.matchBase(first)
        case .normal:
            let stripped = first.replacingOccurrences(of: "Superior ", with: "", options: .caseInsensitive)
            if let base = data.matchBase(stripped) ?? data.baseContained(in: stripped) {
                item.baseType = base
                item.name = base
            } else {
                // White text that isn't a known base: not an item tooltip.
                item.rarity = .unknown
                item.name = Self.titleCase(first)
            }
        case .currency:
            item.name = data.matchBase(first) ?? Self.titleCase(first)
        case .gem:
            item.baseType = data.matchBase(first)
            item.name = item.baseType ?? Self.titleCase(first)
        case .unknown:
            item.name = Self.titleCase(first)
            if texts.count >= 2 { item.baseType = texts[1] }
        }
    }

    static func rarity(fromColors colors: [TextColor]) -> Rarity {
        var counts: [TextColor: Int] = [:]
        for c in colors { counts[c, default: 0] += 1 }
        guard let top = counts.filter({ $0.key != .other }).max(by: { $0.value < $1.value })?.key else { return .unknown }
        switch top {
        case .rare: return .rare
        case .unique: return .unique
        case .magic: return .magic
        case .currency: return .currency
        case .gem: return .gem
        case .white: return .normal
        default: return .unknown
        }
    }

    // MARK: - Body

    private func parseSpecial(_ raw: String, into item: inout ParsedItem) -> Bool {
        // OCR reads PoE 1's property bullets as "•" or "»": drop leading punctuation.
        let text = String(raw.drop { !($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-") })
        let lower = text.lowercased()
        if lower == "corrupted" { item.corrupted = true; return true }
        if lower.hasPrefix("unidentified") {        // "UNIDENTIFIED (TIER 5)"
            item.unidentified = true
            if let t = TextUtil.numbers(in: text).first { item.properties["Unidentified Tier"] = String(Int(t)) }
            return true
        }
        // "Item Level: 80", or with the advanced view "Body Armour: Item Level 80" (class and level on one line).
        if let r = lower.range(of: "item level"),
           lower[..<r.lowerBound].allSatisfy({ $0.isLetter || $0 == " " || $0 == ":" }) {
            item.itemLevel = TextUtil.numbers(in: String(lower[r.upperBound...])).first.map { Int($0) }
            return true
        }
        if let r = lower.range(of: "stack size") {
            // Junk can precede it when Vision merges the row with stash text ("3620 3OSTACK SIZE: 5/20").
            let n = TextUtil.numbers(in: String(lower[r.upperBound...]).replacingOccurrences(of: "/", with: " / "))
            item.stackSize = n.first.map { Int(abs($0)) }
            if n.count > 1 { item.maxStackSize = Int(abs(n[1])) }
            return true
        }
        if lower.hasPrefix("quality") {
            item.quality = TextUtil.numbers(in: text).first.map { Int(abs($0)) }
            return true
        }
        if item.rarity == .gem, lower.hasPrefix("level") {
            // The first "Level:" is the gem's; later ones are stray labels merged into other rows.
            if item.gemLevel == nil { item.gemLevel = TextUtil.numbers(in: text).first.map { Int($0) } }
            return true
        }
        if lower.hasPrefix("requires") || lower.hasPrefix("right click") || lower.hasPrefix("place into")
            || lower.hasPrefix("shift click") || lower.hasPrefix("can be used") {
            return true
        }
        if data.game == .poe1 {
            if Self.poe1Ignored.contains(TextUtil.normalize(text)) { return true }
            // Stash price notes ("Note: ~price 5 chaos"), map instructions.
            if lower.hasPrefix("note:") || lower.hasPrefix("travel to this") || lower.hasPrefix("can only be used") { return true }
        }
        return false
    }

    private static let rollRange = try! NSRegularExpression(pattern: #"\(\s*[+\-]?\d+(?:\.\d+)?\s*-\s*[+\-]?\d+(?:\.\d+)?\s*\)"#)

    /// The advanced item view (Alt, or "advanced mod descriptions" on) puts each mod's roll range after its value:
    /// "+80(70-84) to maximum Life" -> "+80 to maximum Life".
    static func stripRollRanges(_ s: String) -> String {
        guard s.contains("(") else { return s }
        let ns = s as NSString
        return rollRange.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// "Armour: 412" -> ("Armour", "412"). Only for known property labels. Tolerates OCR junk before the
    /// label ("emS : Physical Damage: 176-313") and small typos ("Elemental Damace"), returning the real label.
    static func property(_ text: String) -> (String, String)? {
        for colon in text.indices.reversed() where text[colon] == ":" {
            let label = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let key = TextUtil.normalize(label)
            if knownProperties.contains(key) { return (label, value) }
            let words = key.split(separator: " ")
            for start in words.indices {
                let tail = words[start...].joined(separator: " ")
                if knownProperties.contains(tail) { return (titled(tail), value) }
                if tail.count >= 6, let hit = knownProperties.first(where: { TextUtil.similarity($0, tail) >= 0.86 }) {
                    return (titled(hit), value)
                }
            }
        }
        return nil
    }

    private static func titled(_ s: String) -> String {
        s.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private func modLine(_ raw: String, color: TextColor) -> ModLine? {
        // "GRANTS SKILL: LEVEL 17 PURITY OF FIRE (MAX LEVEL 18)" -> drop the trailing note.
        let text = raw.replacingOccurrences(of: #"\s*\((max level|augmented|implicit|rune|enchant)[^)]*\)\s*$"#,
                                            with: "", options: [.regularExpression, .caseInsensitive])
        guard data.matchStat(text) != nil else { return nil }
        let kind: ModKind
        switch color {
        case .enchant: kind = data.game == .poe1 ? .crafted : .rune
        case .fractured: kind = .fractured
        case .desecrated: kind = .desecrated
        default: kind = .explicit
        }
        return ModLine(text: text, kind: kind, values: TextUtil.numbers(in: text))
    }

    // MARK: - Blocks

    /// Splits lines into blocks using explicit separators or vertical gaps between OCR boxes.
    static func blocks(from lines: [OCRLine]) -> [[OCRLine]] {
        let hasRects = lines.contains { $0.rect != .zero }
        var blocks: [[OCRLine]] = [[]]
        if !hasRects {
            for l in lines {
                if TextUtil.clean(l.text) == separator { if !(blocks.last?.isEmpty ?? true) { blocks.append([]) } }
                else { blocks[blocks.count - 1].append(l) }
            }
            return blocks.filter { !$0.isEmpty }
        }
        let heights = lines.map(\.rect.height).sorted()
        let h = heights.isEmpty ? 20 : heights[heights.count / 2]
        for (i, l) in lines.enumerated() {
            if i > 0 {
                let prev = lines[i - 1]
                let gap = l.rect.minY - prev.rect.maxY
                if gap > 0.75 * h || (i == 1 && prev.rect.height > h * 1.15 && gap > 0.35 * h) {
                    blocks.append([])
                }
            }
            blocks[blocks.count - 1].append(l)
        }
        return blocks.filter { !$0.isEmpty }
    }
}
