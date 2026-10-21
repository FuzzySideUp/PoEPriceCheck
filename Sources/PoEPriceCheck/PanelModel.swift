import Foundation
import PoECore
import SwiftUI

struct NinjaInfo {
    var price: NinjaPrice
    var exaltedPerDivine: Double
    var stack: Int?
    var fetched: Date
}

@MainActor
final class PanelModel: ObservableObject {
    enum Phase { case reading, pricing, done, error }

    @Published var phase: Phase = .reading
    @Published var status = "Reading tooltip…"
    @Published var item: ParsedItem?
    @Published var ninja: NinjaInfo?
    @Published var search: RareSearch? { didSet { if oldValue != nil, search != lastRunSearch { dirty = true } } }
    @Published var result: TradeResult?
    @Published var searching = false
    @Published var dirty = false
    @Published var error: String?
    @Published var ocrLines: [String] = []
    @Published var showOCR = false
    @Published var league = ""
    @Published var zoom: CGFloat = 1
    @Published var exaltedPerDivine: Double = 0
    @Published var canTradeSearch = false
    @Published var needsPermission = false

    var lastRunSearch: RareSearch?
    var onSearch: ((RareSearch) -> Void)?
    var onTradeSearch: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onClose: (() -> Void)?
    var onOpenPermissionSettings: (() -> Void)?

    func reset() {
        phase = .reading
        status = "Reading tooltip…"
        item = nil; ninja = nil; search = nil; result = nil; lastRunSearch = nil
        searching = false; dirty = false; error = nil; ocrLines = []; showOCR = false
        canTradeSearch = false; needsPermission = false
    }

    func fail(_ message: String) {
        phase = .error
        error = message
        searching = false
    }

    // MARK: Formatting

    func format(divine: Double) -> String {
        if divine >= 1 { return String(format: divine >= 10 ? "%.0f div" : "%.1f div", divine) }
        if exaltedPerDivine > 0 {
            let ex = divine * exaltedPerDivine
            return ex >= 10 ? String(format: "%.0f ex", ex) : String(format: "%.1f ex", ex)
        }
        return String(format: "%.3f div", divine)
    }

    static func shortCurrency(_ c: String) -> String {
        ["exalted": "ex", "divine": "div", "chaos": "c", "regal": "regal", "alch": "alch", "annul": "annul",
         "vaal": "vaal", "aug": "aug", "transmute": "trans", "mirror": "mirror"][c] ?? c
    }

    static func age(_ d: Date?) -> String {
        guard let d else { return "" }
        let s = -d.timeIntervalSinceNow
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
