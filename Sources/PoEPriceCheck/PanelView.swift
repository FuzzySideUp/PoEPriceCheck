import PoECore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel

    private var z: CGFloat { model.zoom }
    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * z, weight: weight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * z) {
            header
            Divider().overlay(Color.white.opacity(0.15))
            content
            footer
        }
        .padding(12 * z)
        .frame(width: 430 * z, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * z).fill(Color(red: 0.07, green: 0.065, blue: 0.06).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10 * z).stroke(Color(red: 0.55, green: 0.45, blue: 0.3).opacity(0.7), lineWidth: 1))
        .foregroundStyle(Color(white: 0.88))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var rarityColor: Color {
        switch model.item?.rarity {
        case .rare: return Color(red: 1, green: 1, blue: 0.47)
        case .unique: return Color(red: 0.86, green: 0.47, blue: 0.2)
        case .magic: return Color(red: 0.55, green: 0.55, blue: 1)
        case .currency: return Color(red: 0.8, green: 0.75, blue: 0.6)
        case .gem: return Color(red: 0.2, green: 0.75, blue: 0.7)
        default: return Color(white: 0.9)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2 * z) {
                if let item = model.item {
                    Text(item.name ?? item.baseType ?? "Unknown item").font(font(16, .semibold)).foregroundStyle(rarityColor)
                    if let b = item.baseType, b != item.name {
                        Text(b).font(font(13)).foregroundStyle(rarityColor.opacity(0.85))
                    }
                    let bits = [item.itemLevel.map { "iLvl \($0)" }, item.stackSize.map { "Stack \($0)" },
                                item.gemLevel.map { "Lvl \($0)" }, item.corrupted ? "Corrupted" : nil,
                                item.unidentified ? "Unidentified" : nil].compactMap { $0 }
                    if !bits.isEmpty { Text(bits.joined(separator: " · ")).font(font(11)).foregroundStyle(.secondary) }
                } else {
                    Text("Price check").font(font(16, .semibold))
                }
            }
            Spacer()
            Button { model.onClose?() } label: { Image(systemName: "xmark").font(font(12)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let err = model.error {
            Text(err).font(font(12)).foregroundStyle(Color(red: 1, green: 0.5, blue: 0.45)).fixedSize(horizontal: false, vertical: true)
            if model.needsPermission {
                Button("Open Screen Recording settings") { model.onOpenPermissionSettings?() }.font(font(12))
            }
        }
        if model.phase == .reading || (model.phase == .pricing && model.search == nil && model.ninja == nil && model.error == nil) {
            HStack(spacing: 8 * z) {
                ProgressView().controlSize(.small)
                Text(model.status).font(font(12)).foregroundStyle(.secondary)
            }
        }
        if let n = model.ninja { ninjaSection(n) }
        if model.search != nil { rareSection }
        if model.ninja == nil, model.search == nil, model.showsLinks, model.result != nil || model.searching { linksPicker }
        if model.canTradeSearch && model.search == nil {
            HStack {
                Button(model.searching ? "Searching…" : "Search trade listings") { model.onTradeSearch?() }
                    .disabled(model.searching).font(font(12))
            }
        }
        if model.search == nil, let r = model.result { listings(r) }
        if !model.ocrLines.isEmpty {
            DisclosureGroup(isExpanded: $model.showOCR) {
                Text(model.ocrLines.joined(separator: "\n")).font(.system(size: 10 * z, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } label: { Text("OCR text").font(font(10)).foregroundStyle(.secondary) }
        }
    }

    private func ninjaSection(_ n: NinjaInfo) -> some View {
        VStack(alignment: .leading, spacing: 4 * z) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.format(divine: n.price.divine)).font(font(22, .bold))
                Text("each").font(font(11)).foregroundStyle(.secondary)
                Spacer()
                if n.price.divine < 1, n.smallPerDivine > 0 {
                    Text(String(format: "%.4f div", n.price.divine)).font(font(11)).foregroundStyle(.secondary)
                } else if n.smallPerDivine > 0 {
                    Text(String(format: "%.0f %@", n.price.divine * n.smallPerDivine, model.game.smallCurrencyShort))
                        .font(font(11)).foregroundStyle(.secondary)
                }
            }
            if let s = n.stack, s > 1 {
                Text("Stack of \(s): \(model.format(divine: n.price.divine * Double(s)))").font(font(13, .medium))
            }
            let listed = n.price.category.hasPrefix("Unique") || model.game == .poe1 && n.price.links != nil
            let vol = n.price.volume.map { listed ? "\(Int($0)) listed" : "\(model.format(divine: $0))/day volume" } ?? ""
            let linked = n.price.links.map { "\($0)L · " } ?? ""
            Text("poe.ninja · \(linked)\(n.price.category) · \(vol) · \(PanelModel.age(n.fetched)) old")
                .font(font(10)).foregroundStyle(.secondary)
            if model.showsLinks { linksPicker }
        }
    }

    /// PoE 1: OCR can't see sockets, so the user says how many are linked.
    private var linksPicker: some View {
        HStack(spacing: 6 * z) {
            Text("Links").font(font(11))
            Picker("", selection: Binding(get: { model.links ?? 0 }, set: {
                model.links = $0 == 0 ? nil : $0
                model.onLinksChanged?()
            })) {
                Text("Any").tag(0)
                Text("5L").tag(5)
                Text("6L").tag(6)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150 * z)
            .font(font(11))
            Spacer()
        }
    }

    // MARK: Rare

    @ViewBuilder private var rareSection: some View {
        if let search = model.search {
            VStack(alignment: .leading, spacing: 3 * z) {
                ForEach(Array(search.filters.enumerated()), id: \.offset) { idx, f in
                    Toggle(isOn: Binding(get: { model.search?.filters[idx].enabled ?? false },
                                         set: { model.search?.filters[idx].enabled = $0 })) {
                        HStack {
                            Text(f.display(margin: search.margin)).font(font(12)).foregroundStyle(f.enabled ? .primary : .secondary)
                            Spacer()
                            if !f.valueless { Text(StatFilter.fmtValue(f.rolled)).font(font(10)).foregroundStyle(.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if search.filters.isEmpty {
                    Text("No searchable stats recognised — searching by base only.").font(font(11)).foregroundStyle(.secondary)
                }
                Divider().overlay(Color.white.opacity(0.1))
                if let cat = search.category {
                    Toggle(isOn: Binding(get: { !(model.search?.useBaseType ?? false) }, set: { model.search?.useBaseType = !$0 })) {
                        Text("Any \(Self.categoryName(cat, game: model.game)) (off = \(search.baseType ?? "this base") only)").font(font(11))
                    }.toggleStyle(.checkbox)
                }
                if let floor = search.itemLevelFloor {
                    Toggle(isOn: Binding(get: { model.search?.useItemLevel ?? false }, set: { model.search?.useItemLevel = $0 })) {
                        Text("Item level ≥ \(floor)").font(font(11))
                    }.toggleStyle(.checkbox)
                }
                Toggle(isOn: Binding(get: { model.search?.nonCorruptedOnly ?? false }, set: { model.search?.nonCorruptedOnly = $0 })) {
                    Text("Non-corrupted only").font(font(11))
                }.toggleStyle(.checkbox)
                if model.showsLinks { linksPicker }
                HStack(spacing: 6 * z) {
                    Text("Min values").font(font(11))
                    Button("−") { adjustMargin(-0.05) }.font(font(11))
                    Text("\(Int((search.margin * 100).rounded()))% below roll").font(font(11, .medium)).frame(minWidth: 110 * z)
                    Button("+") { adjustMargin(0.05) }.font(font(11))
                    Spacer()
                    Button(model.searching ? "Searching…" : (model.dirty || model.result == nil ? "Search" : "Search again")) {
                        if let s = model.search { model.onSearch?(s) }
                    }
                    .font(font(12, .semibold))
                    .disabled(model.searching)
                    .keyboardShortcut(.defaultAction)
                }
            }
            if !search.relaxNotes.isEmpty || !(model.result?.search?.relaxNotes.isEmpty ?? true) {
                let notes = model.result?.search?.relaxNotes ?? search.relaxNotes
                Text("Auto-relaxed (too few results): " + notes.joined(separator: "; "))
                    .font(font(10)).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.4)).fixedSize(horizontal: false, vertical: true)
            }
            if let r = model.result { listings(r) }
        }
    }

    private func adjustMargin(_ delta: Double) {
        guard var s = model.search else { return }
        s.margin = min(0.6, max(0, ((s.margin + delta) * 100).rounded() / 100))
        model.search = s
    }

    static func categoryName(_ c: String, game: Game = .poe2) -> String {
        let last = c.split(separator: ".").last.map(String.init) ?? c
        let names = ["chest": "body armour", "onemace": "one-hand mace", "twomace": "two-hand mace", "onesword": "one-hand sword",
                     "twosword": "two-hand sword", "oneaxe": "one-hand axe", "twoaxe": "two-hand axe",
                     "warstaff": game == .poe1 ? "warstaff" : "quarterstaff",
                     "basesword": "one-hand sword", "basemace": "one-hand mace", "basedagger": "dagger", "basestaff": "staff",
                     "runedagger": "rune dagger", "rapier": "thrusting sword", "base": "jewel", "abyss": "abyss jewel",
                     "cluster": "cluster jewel", "trinket": "trinket", "rod": "fishing rod"]
        return names[last] ?? last
    }

    // MARK: Listings

    private func listings(_ r: TradeResult) -> some View {
        VStack(alignment: .leading, spacing: 3 * z) {
            HStack {
                Text("\(r.total) listed").font(font(12, .semibold))
                if model.dirty { Text("(filters changed)").font(font(10)).foregroundStyle(.orange) }
                Spacer()
                Button("Open on trade site") { model.onOpenURL?(r.webURL) }.font(font(11)).buttonStyle(.link)
            }
            if r.listings.isEmpty {
                Text("No priced listings. Untick a stat or widen the margin.").font(font(11)).foregroundStyle(.secondary)
            } else {
                let divs = r.listings.compactMap(\.divine).sorted()
                if let low = divs.first {
                    let mid = divs[divs.count / 2]
                    Text("Cheapest \(model.format(divine: low)) · median of \(divs.count): \(model.format(divine: mid))")
                        .font(font(13, .bold))
                }
                ForEach(r.listings) { l in
                    HStack {
                        Text("\(StatFilter.fmtValue(l.amount)) \(PanelModel.shortCurrency(l.currency))").font(font(12, .medium))
                            .frame(width: 110 * z, alignment: .leading)
                        // Converted price, unless it would just repeat the listing (divine, or chaos/exalted below 1 div).
                        if let d = l.divine, l.currency != "divine", !(l.currency == model.game.smallCurrency && d < 1) {
                            Text("≈ \(model.format(divine: d))").font(font(10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let ilvl = l.itemLevel, ilvl > 0 { Text("i\(ilvl)").font(font(10)).foregroundStyle(.secondary) }
                        Text(PanelModel.age(l.indexed)).font(font(10)).foregroundStyle(.secondary).frame(width: 34 * z, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            let game = (model.game == .poe1 ? "PoE 1" : "PoE 2") + (model.autoGame ? " (auto)" : "")
            Text(model.league.isEmpty ? game : "\(game) · \(model.league)").font(font(10)).foregroundStyle(.secondary)
                .help(model.gameReason)
            Spacer()
            Text("Esc to close").font(font(10)).foregroundStyle(.secondary)
        }
    }
}

extension StatFilter {
    static func fmtValue(_ v: Double) -> String { fmt(v) }
}
