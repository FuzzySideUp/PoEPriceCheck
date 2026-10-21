import Foundation

public enum TextUtil {
    private static let numberRegex = try! NSRegularExpression(pattern: #"[+\-]?\d+(?:[.,]\d+)?"#)

    /// Cleans OCR output: unifies quotes/dashes, collapses whitespace.
    public static func clean(_ s: String) -> String {
        var t = s
        for (a, b) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                       ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2212}", "-"), ("\u{00A0}", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// All numbers in the line, signs kept ("+12%" -> 12, "-5" -> -5).
    public static func numbers(in s: String) -> [Double] {
        let ns = s as NSString
        return numberRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "+", with: ""))
        }
    }

    /// Replaces every number (and its sign) with "#", lowercases and strips punctuation that
    /// OCR tends to get wrong, so a tooltip line and a trade stat template compare equal.
    public static func templateKey(_ s: String) -> String {
        let ns = s as NSString
        let replaced = numberRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "#")
        return normalize(replaced)
    }

    public static func normalize(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for ch in clean(s).lowercased() {
            if ch.isLetter || ch.isNumber || ch == "#" || ch == "%" {
                out.append(ch)
                lastSpace = false
            } else if ch == " " || ch == "-" || ch == "/" {
                if !lastSpace && !out.isEmpty { out.append(" ") }
                lastSpace = true
            }
            // other punctuation (+ , . ' : ( ) ) dropped
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Levenshtein similarity in 0...1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(Swift.max(x.count, y.count))
    }
}
