import Foundation

/// Client-side limiter for GGG's X-Rate-Limit-* headers ("max:period:penalty,...").
/// Keeps one request of headroom under every rule and honours Retry-After on 429.
public actor RateLimiter {
    struct Rule { let max: Int; let period: TimeInterval }

    private var rules: [String: [Rule]]
    private var history: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(defaults: [String: String]) {
        var r: [String: [Rule]] = [:]
        for (policy, header) in defaults { r[policy] = Self.parse(header) }
        rules = r
    }

    static func parse(_ header: String) -> [Rule] {
        header.split(separator: ",").compactMap { part in
            let f = part.split(separator: ":").compactMap { Double($0) }
            guard f.count >= 2 else { return nil }
            return Rule(max: Int(f[0]), period: f[1])
        }
    }

    /// Seconds to wait before a request under `policy` is safe. 0 = go.
    public func delay(for policy: String, now: Date = Date()) -> TimeInterval {
        var wait: TimeInterval = 0
        if let until = blockedUntil[policy], until > now { wait = until.timeIntervalSince(now) }
        let past = history[policy] ?? []
        for rule in rules[policy] ?? [] {
            let window = past.filter { now.timeIntervalSince($0) < rule.period }
            let allowed = max(1, rule.max - 1)
            if window.count >= allowed, let oldest = window.sorted().dropLast(allowed - 1).last {
                wait = max(wait, rule.period - now.timeIntervalSince(oldest) + 0.25)
            }
        }
        return wait
    }

    /// Waits as needed and records the request.
    public func acquire(_ policy: String) async throws {
        while true {
            let d = delay(for: policy)
            if d <= 0 { break }
            try await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
        }
        let now = Date()
        history[policy, default: []].append(now)
        history[policy] = history[policy]!.filter { now.timeIntervalSince($0) < 3600 * 6 }
    }

    /// Updates rules from response headers.
    public func update(_ policy: String, headers: [AnyHashable: Any], status: Int) {
        func header(_ name: String) -> String? {
            for (k, v) in headers where (k as? String)?.lowercased() == name.lowercased() { return v as? String }
            return nil
        }
        var newRules: [Rule] = []
        for kind in ["Ip", "Account", "Client"] {
            if let h = header("X-Rate-Limit-\(kind)") { newRules += Self.parse(h) }
            // If the server already counts us near a limit, back off for that window.
            if let state = header("X-Rate-Limit-\(kind)-State"), let limits = header("X-Rate-Limit-\(kind)") {
                let s = Self.parse(state), l = Self.parse(limits)
                for (cur, lim) in zip(s, l) where cur.max >= lim.max - 1 {
                    let until = Date().addingTimeInterval(lim.period)
                    blockedUntil[policy] = max(blockedUntil[policy] ?? .distantPast, until)
                }
                // Third field of state is an active penalty in seconds.
                for part in state.split(separator: ",") {
                    let f = part.split(separator: ":").compactMap { Double($0) }
                    if f.count == 3, f[2] > 0 {
                        blockedUntil[policy] = max(blockedUntil[policy] ?? .distantPast, Date().addingTimeInterval(f[2]))
                    }
                }
            }
        }
        if !newRules.isEmpty { rules[policy] = newRules }
        if status == 429 {
            let retry = header("Retry-After").flatMap(Double.init) ?? 60
            blockedUntil[policy] = Date().addingTimeInterval(retry)
        }
    }

    public func secondsBlocked(_ policy: String) -> TimeInterval {
        max(0, (blockedUntil[policy] ?? .distantPast).timeIntervalSinceNow)
    }
}
