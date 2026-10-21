import Foundation

/// Plain-text log at ~/Library/Application Support/PoEPriceCheck/log.txt (trimmed at 1 MB).
enum Log {
    private static let url = Settings.supportDirectory.appendingPathComponent("log.txt")
    private static let queue = DispatchQueue(label: "PoEPriceCheck.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func info(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
