import AppKit
import ImageIO
import PoECore
import UniformTypeIdentifiers

/// Hotkey → capture → OCR → parse → price → panel.
@MainActor
final class PriceCheckController {
    /// Data and API clients for one game. Both stay loaded so switching back keeps caches and rate-limit state.
    struct GameContext {
        let data: GameData
        let ninja: NinjaClient
        let trade: TradeClient
        var knownLeagues: [String]
    }
    private var contexts: [Game: GameContext] = [:]
    private(set) var game: Game
    var data: GameData { contexts[game]!.data }
    var ninja: NinjaClient { contexts[game]!.ninja }
    var trade: TradeClient { contexts[game]!.trade }
    var knownLeagues: [String] {
        get { contexts[game]!.knownLeagues }
        set { contexts[game]!.knownLeagues = newValue }
    }
    let model = PanelModel()
    private(set) lazy var panel: ResultPanel = {
        let p = ResultPanel(model: model)
        p.onDismiss = { [weak self] in self?.task?.cancel() }
        return p
    }()
    private var task: Task<Void, Never>?
    private var resolvedLeague: [Game: String] = [:]
    private var lastCapture: ScreenCapturer.Capture?

    static func defaultLeagues(_ game: Game) -> [String] {
        game == .poe1 ? ["Standard", "Hardcore"]
            : ["Forbidden Rites", "Runes of Aldur", "Standard", "HC Forbidden Rites", "HC Runes of Aldur", "Hardcore"]
    }

    static func makeContext(_ game: Game) throws -> GameContext {
        let dir = Bundle.main.resourceURL!.appendingPathComponent(game.dataFolder)
        return GameContext(data: try GameData(directory: dir, game: game),
                           ninja: NinjaClient(cacheDirectory: Settings.supportDirectory, userAgent: Settings.userAgent, game: game),
                           trade: TradeClient(userAgent: Settings.userAgent, game: game),
                           knownLeagues: defaultLeagues(game))
    }

    init() throws {
        game = Settings.game
        contexts[game] = try Self.makeContext(game)
        if Settings.autoGame { try loadAllGames() }
        model.game = game
        model.autoGame = Settings.autoGame

        model.onClose = { [weak self] in self?.panel.dismiss() }
        model.onOpenURL = { NSWorkspace.shared.open($0) }
        model.onSearch = { [weak self] s in self?.runRareSearch(s, autoRelax: false) }
        model.onTradeSearch = { [weak self] in self?.runNameSearch() }
        model.onLinksChanged = { [weak self] in self?.linksChanged() }
        model.onOpenPermissionSettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func loadAllGames() throws {
        for g in Game.allCases where contexts[g] == nil { contexts[g] = try Self.makeContext(g) }
    }

    /// Menu › Game: nil = Auto (detect from each tooltip), else a fixed game. Loads data on first use and warms caches.
    func setGameMode(_ fixed: Game?) throws {
        task?.cancel()
        panel.dismiss()
        if let g = fixed {
            if contexts[g] == nil { contexts[g] = try Self.makeContext(g) }
            Settings.autoGame = false
            use(g)
        } else {
            try loadAllGames()
            Settings.autoGame = true
        }
        model.autoGame = Settings.autoGame
        Log.info("game mode: \(fixed?.rawValue ?? "auto") (current \(game.rawValue))")
        warmUp()
    }

    private func use(_ g: Game) {
        Settings.game = g
        game = g
        model.game = g
    }

    /// Warm caches so the first check is quick.
    func warmUp() {
        // Auto mode warms both games so the first check of either is quick.
        let games = Settings.autoGame ? Array(contexts.keys) : [game]
        for g in games { warmUp(g) }
        warmUpVision()
    }

    private func warmUp(_ g: Game) {
        guard let ctx = contexts[g] else { return }
        Task { if let ls = try? await ctx.trade.leagues() { contexts[g]?.knownLeagues = ls } }
        Task {
            let t0 = Date()
            guard let league = try? await league(for: g) else { return }
            do {
                let snap = try await ctx.ninja.ensure(league: league)
                Log.info(String(format: "warmUp: ninja %d prices for %@ in %.2fs", snap.prices.count, league, Date().timeIntervalSince(t0)))
            } catch {
                Log.info("warmUp: ninja failed: \(error)")
            }
        }
    }

    private func warmUpVision() {
        Task.detached(priority: .utility) {
            // First Vision call loads the OCR model; do it now rather than on the first hotkey.
            let t0 = Date()
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let img = ctx?.makeImage() { _ = try? TooltipReader.recognize(img) }
            Log.info(String(format: "warmUp: Vision ready in %.1fs", Date().timeIntervalSince(t0))
                     + (TooltipReader.fallbackReason.map { " on \(TooltipReader.engine) (\($0))" } ?? ""))
        }
    }

    /// Network self-test: `open PoEPriceCheck.app --args --selftest`, results go to the log.
    func selfTest() {
        Task {
            var t0 = Date()
            let league = (try? await league()) ?? "?"
            Log.info(String(format: "selftest: league=%@ %.2fs", league, Date().timeIntervalSince(t0)))
            t0 = Date()
            do {
                let ls = try await trade.leagues()
                Log.info(String(format: "selftest: trade leagues %@ %.2fs", ls.joined(separator: "|"), Date().timeIntervalSince(t0)))
            } catch { Log.info("selftest: trade leagues failed \(error)") }
        }
    }

    /// Settings › League, else poe.ninja's current league (4s timeout), else the last one that worked.
    func league() async throws -> String { try await league(for: game) }

    func league(for game: Game) async throws -> String {
        if let l = Settings.league(for: game) { return l }
        if let l = Settings.detectedLeague(for: game) { return l }
        if let l = resolvedLeague[game] { return l }
        let t0 = Date()
        guard let ninja = contexts[game]?.ninja else { throw PriceError.noData("\(game.title) data not loaded") }
        do {
            let l = try await withTimeout(4) { try await ninja.currentLeague() }
            Log.info(String(format: "league: %@ from poe.ninja (%@) in %.2fs", l, game.rawValue, Date().timeIntervalSince(t0)))
            resolvedLeague[game] = l
            Settings.setLastLeague(l, for: game)
            return l
        } catch {
            let cached = await ninja.snapshot?.league
            let fallback = Settings.lastLeague(for: game) ?? cached
            Log.info(String(format: "league lookup failed after %.2fs (%@); using %@", Date().timeIntervalSince(t0),
                            "\(error)", fallback ?? "nothing"))
            if let fallback { return fallback }
            throw error
        }
    }

    // MARK: - Trigger

    func trigger() {
        Log.info("trigger: mouse=\(NSEvent.mouseLocation) permission=\(ScreenCapturer.hasPermission) frontApp=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        task?.cancel()
        model.reset()
        model.zoom = Self.zoom(for: NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            panel.show(near: NSEvent.mouseLocation, tooltipCenterX: nil, on: screen)
        }
        task = Task { await run() }
    }

    static func zoom(for screen: NSScreen?) -> CGFloat {
        if let z = UserDefaults.standard.object(forKey: "zoom") as? Double { return z }
        guard let s = screen else { return 1 }
        return s.frame.width >= 3000 ? 1.6 : (s.frame.width >= 2200 ? 1.25 : 1)
    }

    private func run() async {
        guard ScreenCapturer.hasPermission else {
            Log.info("no Screen Recording permission")
            ScreenCapturer.requestPermission()
            model.needsPermission = true
            model.fail("PoEPriceCheck needs Screen Recording permission to read tooltips. Allow it in System Settings, then quit and reopen the app.")
            return
        }
        do {
            var (capture, read, item) = try await readOnce()
            if Task.isCancelled { return }
            // GeForce NOW frames can be smeared by video compression as the tooltip appears: try once more.
            if !(await isConfident(item)) {
                Log.info("weak read (\(item.rarity) \(item.name ?? "-")); re-capturing")
                try await Task.sleep(nanoseconds: 300_000_000)
                let second = try await readOnce()
                if await isConfident(second.2) || item.rarity == .unknown { (capture, read, item) = second }
            }
            if Task.isCancelled { return }
            model.ocrLines = read.lines.map { "[\($0.color.rawValue)] \($0.text)" }
            if let l = TooltipReader.detectLeague(in: read.allLines, known: knownLeagues), l != Settings.detectedLeague {
                Settings.detectedLeague = l
                Log.info("league detected on screen: \(l)")
            }

            // Put the panel on the side away from the tooltip.
            if !read.tooltipRect.isNull {
                let centerX = capture.regionInScreen.minX + read.tooltipRect.midX / capture.scale
                panel.reposition(tooltipCenterX: centerX, on: capture.screen)
            }

            if Settings.saveCaptures { save(capture, read: read, item: item) }
            var recognised = item.rarity != .unknown
            if !recognised, let n = item.name, await ninja.lookup(name: n, baseType: nil, corrupted: false) != nil { recognised = true }
            guard !read.lines.isEmpty, recognised else {
                model.fail("Couldn't find an item tooltip under the cursor. Hover an item so its tooltip is showing, then press the hotkey.")
                return
            }
            model.item = item
            model.phase = .pricing
            model.status = "Fetching prices…"
            let league = try await league()
            model.league = league
            try await price(item, league: league)
        } catch is CancellationError {
            Log.info("cancelled")
        } catch {
            Log.info("error: \(error)")
            model.fail(error.localizedDescription)
        }
    }

    private func readOnce() async throws -> (ScreenCapturer.Capture, TooltipReader.Result, ParsedItem) {
        let capture = try await ScreenCapturer.captureAroundMouse()
        lastCapture = capture
        Log.info("captured \(capture.image.width)x\(capture.image.height) cursor=\(capture.cursorInImage) scale=\(capture.scale)")
        let image = capture.image, cursor = capture.cursorInImage
        let read = try await Task.detached(priority: .userInitiated) {
            try TooltipReader.read(image: image, cursor: cursor)
        }.value
        Log.info(String(format: "ocr %.2fs%@: %d lines total, %d in tooltip %@", read.ocrSeconds,
                        TooltipReader.engine == .neuralEngine ? "" : " (\(TooltipReader.engine))", read.allLines.count, read.lines.count, "\(read.tooltipRect)"))
        let item = parse(read, windowTitle: Self.frontWindowTitle())
        Log.info("parsed: rarity=\(item.rarity) name=\(item.name ?? "-") base=\(item.baseType ?? "-") ilvl=\(item.itemLevel.map(String.init) ?? "-") mods=\(item.mods.count)")
        return (capture, read, item)
    }

    /// Parses with the current game, or in Auto mode with whichever game the tooltip turns out to be (switching to it).
    func parse(_ read: TooltipReader.Result, windowTitle title: String?) -> ParsedItem {
        var item = ItemParser(data: data).parse(read.lines)
        if Settings.autoGame, contexts.count > 1 {
            let d = GameDetector(data: contexts.mapValues(\.data))
                .decide(tooltip: read.lines, allLines: read.allLines, leagues: contexts.mapValues(\.knownLeagues), last: game,
                        windowTitle: title)
            Log.info("game: \(d.game.rawValue) (\(d.reason))")
            if let l = d.league { Settings.setDetectedLeague(l, for: d.game) }
            if d.game != game { use(d.game) }
            model.gameReason = d.reason
            item = d.item
        }
        return item
    }

    /// Title of the frontmost app's main window (GeForce NOW or the browser streaming it), logged so we can see
    /// whether it ever names the game. Needs the Screen Recording grant the app already has.
    static func frontWindowTitle() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let titles = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }
        Log.info("window titles: \(titles)")
        return titles.first { GameDetector.game(inTitle: $0) != nil } ?? titles.first
    }

    /// Did the read produce names we actually know?
    private func isConfident(_ item: ParsedItem) async -> Bool {
        switch item.rarity {
        case .unknown: return false
        case .unique: return item.name.map { data.uniqueBases[$0] != nil } ?? false
        case .rare, .magic, .normal: return item.baseType.map { data.category(forBase: $0) != nil } ?? false
        case .currency, .gem:
            guard let n = item.name else { return false }
            if data.matchBase(n) != nil { return true }
            return await ninja.lookup(name: n, baseType: nil, corrupted: false) != nil
        }
    }

    // MARK: - Pricing

    func renderPrice(_ item: ParsedItem, league: String) async throws { try await price(item, league: league) }

    private func price(_ item: ParsedItem, league: String) async throws {
        let t0 = Date()
        let ninja = self.ninja
        let snap = try? await withTimeout(10) { try await ninja.ensure(league: league) }
        Log.info(String(format: "price: ninja snapshot %@ in %.2fs", snap == nil ? "unavailable" : "ok", Date().timeIntervalSince(t0)))
        model.smallPerDivine = snap?.smallPerDivine(game) ?? 0

        // White-text items poe.ninja knows (PoE 1 fragments, scarabs, cards) are priced like currency.
        if item.rarity == .normal, item.mods.isEmpty, let n = item.name, let snap,
           let p = await ninja.lookup(name: n, baseType: nil, corrupted: false) {
            model.ninja = NinjaInfo(price: p, smallPerDivine: snap.smallPerDivine(game), stack: item.stackSize, fetched: snap.fetched)
            Log.info(String(format: "ninja: %@ = %.4f div (%@)", p.name, p.divine, p.category))
            model.phase = .done
            return
        }

        switch item.rarity {
        case .rare, .magic, .normal:
            if item.unidentified || item.rarity == .normal {
                // Base + item level search, plus any anoints (an anointed normal amulet is priced by them).
                var s = RareQueryBuilder(data: data, margin: Settings.margin, status: Settings.status).build(item)
                s.filters = item.unidentified ? [] : s.filters.filter(\.valueless).map { var f = $0; f.enabled = true; return f }
                s.useBaseType = true
                model.search = s
            } else {
                model.search = RareQueryBuilder(data: data, margin: Settings.margin, status: Settings.status).build(item)
            }
            if let s = model.search { runRareSearch(s, autoRelax: true) }
        default:
            let name = item.name ?? item.baseType ?? ""
            if let p = await ninja.lookup(name: name, baseType: item.rarity == .unique ? item.baseType : nil, corrupted: item.corrupted),
               let snap {
                model.ninja = NinjaInfo(price: p, smallPerDivine: snap.smallPerDivine(game), stack: item.stackSize, fetched: snap.fetched)
                Log.info(String(format: "ninja: %@ = %.4f div (%@)", p.name, p.divine, p.category))
                model.phase = .done
                model.canTradeSearch = item.rarity == .unique || item.rarity == .gem
            } else {
                model.canTradeSearch = true
                Log.info("ninja: no price for \(name); trying trade search")
                model.status = "Not on poe.ninja — searching trade…"
                runNameSearch()
            }
        }
    }

    private func rates() async -> [String: Double] {
        await ninja.snapshot?.currencyById ?? [:]
    }

    func runRareSearch(_ search: RareSearch, autoRelax: Bool) {
        guard !model.searching else { return }
        model.searching = true
        model.lastRunSearch = search
        model.dirty = false
        let enabled = search.filters.filter(\.enabled).map { $0.display(margin: search.margin) }
        Log.info("trade search (\(autoRelax ? "auto" : "manual")) margin=\(Int(search.margin * 100))% filters=\(enabled) baseOnly=\(search.useBaseType) ilvl=\(search.useItemLevel)")
        Task {
            do {
                let league = try await league()
                let r = try await trade.price(search, league: league, autoRelax: autoRelax, currencyRates: await rates())
                Log.info("trade result: total=\(r.total) relaxed=\(r.search?.relaxNotes ?? []) prices=\(r.listings.prefix(5).map { "\(StatFilter.fmt($0.amount)) \($0.currency)" })")
                model.result = r
                if autoRelax, let used = r.search, used != search {
                    // Show the filters that were actually used.
                    model.lastRunSearch = used
                    model.search = used
                    model.dirty = false
                }
                model.phase = .done
            } catch {
                Log.info("trade error: \(error)")
                model.error = error.localizedDescription
            }
            model.searching = false
        }
    }

    func runNameSearch() {
        guard let item = model.item, !model.searching else { return }
        model.searching = true
        Task {
            do {
                let league = try await league()
                let isUnique = item.rarity == .unique
                let r = try await trade.priceByName(
                    name: isUnique ? item.name : nil,
                    type: isUnique ? item.baseType : (item.baseType ?? item.name),
                    gemLevel: item.rarity == .gem ? item.gemLevel : nil,
                    corrupted: item.corrupted, links: model.links, league: league, status: Settings.status,
                    currencyRates: await rates())
                Log.info("name search: total=\(r.total) prices=\(r.listings.prefix(5).map { "\(StatFilter.fmt($0.amount)) \($0.currency)" })")
                model.result = r
                model.phase = .done
            } catch {
                Log.info("trade error: \(error)")
                model.error = error.localizedDescription
            }
            model.searching = false
        }
    }

    /// Links picked in the panel (PoE 1). Rare searches take them on the next Search; uniques re-price now.
    private func linksChanged() {
        guard let item = model.item else { return }
        if model.search != nil {
            model.search?.links = model.links
            return
        }
        Task {
            let name = item.name ?? item.baseType ?? ""
            model.result = nil
            if let snap = await ninja.snapshot,
               let p = await ninja.lookup(name: name, baseType: item.rarity == .unique ? item.baseType : nil,
                                          corrupted: item.corrupted, links: model.links),
               model.links == nil || p.links == model.links {
                model.ninja = NinjaInfo(price: p, smallPerDivine: snap.smallPerDivine(game), stack: item.stackSize, fetched: snap.fetched)
                Log.info(String(format: "ninja (%@ links): %@ = %.4f div", model.links.map(String.init) ?? "no", p.name, p.divine))
            } else {
                // poe.ninja has no price for this link count: ask the trade site.
                model.ninja = nil
                model.canTradeSearch = true
                runNameSearch()
            }
        }
    }

    // MARK: - Debug captures

    private func save(_ capture: ScreenCapturer.Capture, read: TooltipReader.Result, item: ParsedItem) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = Settings.capturesDirectory.appendingPathComponent("capture-\(stamp)")
        let png = base.appendingPathExtension("png")
        if let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, capture.image, nil)
            CGImageDestinationFinalize(dest)
        }
        struct Dump: Encodable {
            let cursor: [Double]; let tooltipRect: [Double]; let ocrSeconds: Double
            let tooltip: [OCRLine]; let all: [OCRLine]; let parsed: ParsedItem
        }
        let r = read.tooltipRect.isNull ? CGRect.zero : read.tooltipRect
        let dump = Dump(cursor: [capture.cursorInImage.x, capture.cursorInImage.y],
                        tooltipRect: [r.minX, r.minY, r.width, r.height], ocrSeconds: read.ocrSeconds,
                        tooltip: read.lines, all: read.allLines, parsed: item)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(dump).write(to: base.appendingPathExtension("json"))
    }
}

struct TimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "Timed out after \(Int(seconds))s" }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
