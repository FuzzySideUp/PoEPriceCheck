import CoreGraphics
import Foundation

public enum Rarity: String, Codable, Sendable {
    case normal, magic, rare, unique, currency, gem, unknown
}

/// Text colours used in PoE 2 tooltips. OCR'd lines are classified to the nearest one.
public enum TextColor: String, Codable, Sendable, CaseIterable {
    case white, grey, magic, rare, unique, currency, gem, corrupted, enchant, fractured, desecrated, other

    /// Reference RGB values (0-255) as rendered by the game.
    var reference: [(Double, Double, Double)] {
        switch self {
        case .white: return [(255, 255, 255), (200, 200, 200)]
        case .grey: return [(127, 127, 127), (150, 150, 150)]
        case .magic: return [(136, 136, 255)]
        case .rare: return [(255, 255, 119)]
        case .unique: return [(175, 96, 37), (200, 110, 50)]
        case .currency: return [(170, 158, 130)]
        case .gem: return [(27, 162, 155)]
        case .corrupted: return [(210, 0, 0)]
        case .enchant: return [(184, 218, 242)]
        case .fractured: return [(162, 145, 98)]
        case .desecrated: return [(200, 120, 220)]
        case .other: return []
        }
    }

    /// Brightness-independent classification (tooltips can be dimmed mid fade-in or semi-transparent):
    /// saturated colours are compared after normalising to full brightness; greys by brightness.
    /// Reference values were measured from GeForce NOW captures at 4K.
    public static func classify(r: Double, g: Double, b: Double) -> TextColor {
        let mx = max(r, g, b), mn = min(r, g, b)
        guard mx >= 40 else { return .other }
        let sat = (mx - mn) / mx
        if sat >= 0.25 {
            let k = 255 / mx
            let (nr, ng, nb) = (r * k, g * k, b * k)
            let refs: [(TextColor, (Double, Double, Double))] = [
                (.rare, (255, 230, 114)), (.unique, (255, 124, 49)), (.unique, (255, 159, 83)),
                (.magic, (155, 152, 255)), (.corrupted, (255, 20, 22)), (.gem, (43, 255, 244)),
                (.desecrated, (232, 139, 255)), (.currency, (255, 240, 200)),
            ]
            var best = TextColor.other, bestDist = Double.infinity
            for (c, ref) in refs {
                let d = pow(nr - ref.0, 2) + pow(ng - ref.1, 2) + pow(nb - ref.2, 2)
                if d < bestDist { bestDist = d; best = c }
            }
            return bestDist < 95 * 95 ? best : .other
        }
        if sat >= 0.12 {
            // Low-chroma: cool = enchant/rune light blue, warm = currency tan.
            return b >= r ? .enchant : .currency
        }
        return mx >= 165 ? .white : .grey
    }
}

public struct OCRLine: Codable, Sendable, Equatable {
    public var text: String
    /// Pixel rect in the captured image, top-left origin.
    public var rect: CGRect
    public var color: TextColor
    public var confidence: Float
    /// Brightness (0-255) of the background behind the text; tooltips sit on a near-black panel.
    public var background: Double?

    public init(text: String, rect: CGRect = .zero, color: TextColor = .other, confidence: Float = 1, background: Double? = nil) {
        self.text = text
        self.rect = rect
        self.color = color
        self.confidence = confidence
        self.background = background
    }
}

public enum ModKind: String, Codable, Sendable {
    case explicit, implicit, rune, enchant, fractured, desecrated, crafted
}

public struct ModLine: Codable, Sendable, Equatable {
    public var text: String
    public var kind: ModKind
    public var values: [Double]

    public init(text: String, kind: ModKind, values: [Double]) {
        self.text = text
        self.kind = kind
        self.values = values
    }
}

public struct ParsedItem: Codable, Sendable {
    public var rarity: Rarity = .unknown
    public var name: String?
    public var baseType: String?
    public var category: String?
    public var itemLevel: Int?
    public var quality: Int?
    public var stackSize: Int?
    public var maxStackSize: Int?
    public var gemLevel: Int?
    public var corrupted = false
    public var unidentified = false
    public var properties: [String: String] = [:]
    public var mods: [ModLine] = []
    public var rawLines: [String] = []

    public init() {}

    /// Name to show in the panel header.
    public var displayName: String {
        [name, baseType].compactMap { $0 }.reduced().joined(separator: " — ")
    }
}

extension Array where Element == String {
    /// Drops consecutive duplicates (normal items have name == base).
    func reduced() -> [String] {
        var out: [String] = []
        for s in self where out.last != s { out.append(s) }
        return out
    }
}
