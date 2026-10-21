import Foundation

/// User preferences (UserDefaults).
enum Settings {
    private static let d = UserDefaults.standard

    static var hotKey: HotKey.Combo {
        get {
            if let data = d.data(forKey: "hotKey"), let c = try? JSONDecoder().decode(HotKey.Combo.self, from: data) { return c }
            return HotKey.presets[0]
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "hotKey") }
    }

    /// nil = follow poe.ninja's current league.
    static var league: String? {
        get { d.string(forKey: "league") }
        set { d.set(newValue, forKey: "league") }
    }

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
