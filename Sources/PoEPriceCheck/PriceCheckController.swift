import AppKit
import ImageIO
import PoECore
import UniformTypeIdentifiers

/// Hotkey → capture → OCR → parse → price → panel.
@MainActor
final class PriceCheckController {
    let data: GameData
    let ninja: NinjaClient
    let trade: TradeClient
    let model = PanelModel()
    private(set) lazy var panel: ResultPanel = {
        let p = ResultPanel(model: model)
        p.onDismiss = { [weak self] in self?.task?.cancel() }
        return p
    }()
    private var task: Task<Void, Never>?
    private var resolvedLeague: String?
    private var lastCapture: ScreenCapturer.Capture?
    var knownLeagues = ["Forbidden Rites", "Runes of Aldur", "Standard", "HC Forbidden Rites", "HC Runes of Aldur", "Hardcore"]

    init() throws {
        let dir = Bundle.main.resourceURL!.appendingPathComponent("poe2")
        data = try GameData(directory: dir)
        ninja = NinjaClient(cacheDirectory: Settings.supportDirectory, userAgent: Settings.userAgent)
        trade = TradeClient(userAgent: Settings.userAgent)

        model.onClose = { [weak self] in self?.panel.dismiss() }
        model.onOpenURL = { NSWorkspace.shared.open($0) }
        model.onSearch = { [weak self] s in self?.runRareSearch(s, autoRelax: false) }
        model.onTradeSearch = { [weak self] in self?.runNameSearch() }
        model.onOpenPermissionSettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// Warm caches so the first check is quick.
    func warmUp() {
        Task { knownLeagues = (try? await trade.leagues()) ?? knownLeagues }
        Task {
            let t0 = Date()
            guard let league = try? await league() else { return }
            do {
                let snap = try await ninja.ensure(league: league)
                Log.info(String(format: "warmUp: ninja %d prices for %@ in %.2fs", snap.prices.count, league, Date().timeIntervalSince(t0)))
            } catch {
                Log.info("warmUp: ninja failed: \(error)")
            }
        }
        Task.detached(priority: .utility) {
            // First Vision call loads the OCR model; do it now rather than on the first hotkey.
            let t0 = Date()
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let img = ctx?.makeImage() { _ = try? TooltipReader.recognize(img) }
            Log.info(String(format: "warmUp: Vision ready in %.1fs", Date().timeIntervalSince(t0)))
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
    func league() async throws -> String {
        if let l = Settings.league { return l }
        if let l = UserDefaults.standard.string(forKey: "detectedLeague") { return l }
        if let l = resolvedLeague { return l }
        let t0 = Date()
        do {
            let l = try await withTimeout(4) { try await self.ninja.currentLeague() }
            Log.info(String(format: "league: %@ from poe.ninja in %.2fs", l, Date().timeIntervalSince(t0)))
            resolvedLeague = l
            UserDefaults.standard.set(l, forKey: "lastLeague")
            return l
        } catch {
            let cached = await ninja.snapshot?.league
            let fallback = UserDefaults.standard.string(forKey: "lastLeague") ?? cached
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
            if let l = TooltipReader.detectLeague(in: read.allLines, known: knownLeagues),
               l != UserDefaults.standard.string(forKey: "detectedLeague") {
                UserDefaults.standard.set(l, forKey: "detectedLeague")
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
        Log.info(String(format: "ocr %.2fs: %d lines total, %d in tooltip %@", read.ocrSeconds, read.allLines.count, read.lines.count, "\(read.tooltipRect)"))
        let item = ItemParser(data: data).parse(read.lines)
        Log.info("parsed: rarity=\(item.rarity) name=\(item.name ?? "-") base=\(item.baseType ?? "-") ilvl=\(item.itemLevel.map(String.init) ?? "-") mods=\(item.mods.count)")
        return (capture, read, item)
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
        model.exaltedPerDivine = snap?.exaltedPerDivine ?? 0

        switch item.rarity {
        case .rare, .magic, .normal:
            if item.unidentified || item.rarity == .normal {
                // Base + item level search.
                var s = RareQueryBuilder(data: data, margin: Settings.margin, status: Settings.status).build(item)
                s.filters = []
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
                model.ninja = NinjaInfo(price: p, exaltedPerDivine: snap.exaltedPerDivine, stack: item.stackSize, fetched: snap.fetched)
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
                    corrupted: item.corrupted, league: league, status: Settings.status, currencyRates: await rates())
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
