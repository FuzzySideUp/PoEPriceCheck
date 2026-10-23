import Foundation
import PoECore

/// User preferences (UserDefaults).
enum Settings {
    private static let d = UserDefaults.standard

    /// The game being priced: the one picked in the menu, or in Auto mode the one last detected on screen.
    static var game: Game {
        get { d.string(forKey: "game").flatMap(Game.init(rawValue:)) ?? .poe2 }
        set { d.set(newValue.rawValue, forKey: "game") }
    }

    /// Detect PoE 1 / PoE 2 from each tooltip (default on).
    static var autoGame: Bool {
        get { d.object(forKey: "autoGame") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoGame") }
    }

    /// League-related keys are kept per game; PoE 2 keeps the original key names.
    static func gameKey(_ key: String, _ game: Game = Settings.game) -> String {
        game == .poe2 ? key : "\(key).\(game.rawValue)"
    }

    static var hotKey: HotKey.Combo {
        get {
            if let data = d.data(forKey: "hotKey"), let c = try? JSONDecoder().decode(HotKey.Combo.self, from: data) { return c }
            return HotKey.presets[0]
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "hotKey") }
    }

    /// nil = follow poe.ninja's current league.
    static var league: String? {
        get { league(for: game) }
        set { d.set(newValue, forKey: gameKey("league")) }
    }
    static func league(for g: Game) -> String? { d.string(forKey: gameKey("league", g)) }

    /// League last read from the in-game area overlay.
    static var detectedLeague: String? {
        get { detectedLeague(for: game) }
        set { setDetectedLeague(newValue, for: game) }
    }
    static func detectedLeague(for g: Game) -> String? { d.string(forKey: gameKey("detectedLeague", g)) }
    static func setDetectedLeague(_ l: String?, for g: Game) { d.set(l, forKey: gameKey("detectedLeague", g)) }

    /// Last league poe.ninja reported, for when it can't be reached.
    static func lastLeague(for g: Game) -> String? { d.string(forKey: gameKey("lastLeague", g)) }
    static func setLastLeague(_ l: String, for g: Game) { d.set(l, forKey: gameKey("lastLeague", g)) }

    /// Fraction below each rolled value used as the search minimum.
    static var margin: Double {
        get { d.object(forKey: "margin") as? Double ?? 0.10 }
        set { d.set(newValue, forKey: "margin") }
    }

    /// Trade listing status: available (instant buyout + in person), securable, online, any.
    static var status: String {
        get { d.string(forKey: "status") ?? "available" }
        set { d.set(newValue, forKey: "status") }
    }

    /// Open the app when you log in (see LoginItem).
    static var openAtLogin: Bool {
        get { d.bool(forKey: "openAtLogin") }
        set { d.set(newValue, forKey: "openAtLogin") }
    }

    static var saveCaptures: Bool {
        get { d.bool(forKey: "saveCaptures") }
        set { d.set(newValue, forKey: "saveCaptures") }
    }

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PoEPriceCheck")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var capturesDirectory: URL {
        let url = supportDirectory.appendingPathComponent("captures")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// GGG asks tools to identify themselves; add a contact here if you want one sent.
    static let userAgent = "PoEPriceCheck/0.1 (macOS; personal OCR price-check overlay)"
}
