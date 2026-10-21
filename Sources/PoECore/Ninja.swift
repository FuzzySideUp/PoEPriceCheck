import Foundation

public struct NinjaPrice: Codable, Sendable, Equatable {
    public var name: String
    public var baseType: String?
    public var divine: Double          // price in Divine Orbs
    public var volume: Double?         // exchange volume (divine) or listing count
    public var category: String
    public var corrupted: Bool
}

public struct NinjaSnapshot: Codable, Sendable {
    public var league: String
    public var fetched: Date
    public var exaltedPerDivine: Double
    public var chaosPerDivine: Double
    public var prices: [NinjaPrice]
    /// trade currency id ("exalted", "chaos", ...) -> divine value
    public var currencyById: [String: Double]
}

/// poe.ninja PoE 2 economy prices, cached to disk and refreshed every 15 minutes.
public actor NinjaClient {
    public static let exchangeTypes = ["Currency", "Fragments", "Abyss", "UncutGems", "LineageSupportGems", "Essences",
                                       "SoulCores", "Idols", "Runes", "Ritual", "Expedition", "Delirium", "Breach", "Verisium"]
    public static let stashTypes = ["UniqueWeapons", "UniqueArmours", "UniqueAccessories", "UniqueFlasks", "UniqueCharms",
                                    "UniqueJewels", "UniqueSanctumRelics", "UniqueTablets", "PrecursorTablets"]

    private let session: URLSession
    private let cacheURL: URL
    private let userAgent: String
    public private(set) var snapshot: NinjaSnapshot?
    private var byName: [String: [NinjaPrice]] = [:]
    private var refreshTask: Task<NinjaSnapshot, Error>?
    public var maxAge: TimeInterval = 15 * 60

    public init(cacheDirectory: URL, userAgent: String, session: URLSession = .shared) {
        self.session = session
        self.userAgent = userAgent
        cacheURL = cacheDirectory.appendingPathComponent("ninja-poe2.json")
        if let d = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder.iso.decode(NinjaSnapshot.self, from: d) {
            snapshot = s
            byName = Self.index(s)
        }
    }

    static func index(_ s: NinjaSnapshot) -> [String: [NinjaPrice]] {
        var d: [String: [NinjaPrice]] = [:]
        for p in s.prices { d[TextUtil.normalize(p.name), default: []].append(p) }
        return d
    }

    /// Returns a fresh-enough snapshot for the league, fetching if needed.
    public func ensure(league: String) async throws -> NinjaSnapshot {
        if let s = snapshot, s.league == league, Date().timeIntervalSince(s.fetched) < maxAge { return s }
        if let t = refreshTask { return try await t.value }
        let task = Task { try await self.fetchAll(league: league) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let s = try await task.value
            snapshot = s
            byName = Self.index(s)
            if let d = try? JSONEncoder.iso.encode(s) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: cacheURL)
            }
            return s
        } catch {
            if let s = snapshot, s.league == league { return s }   // stale beats nothing
            throw error
        }
    }

    /// The league poe.ninja currently indexes (softcore, non-Standard), e.g. "Runes of Aldur".
    public func currentLeague() async throws -> String {
        struct S: Decodable { struct L: Decodable { let name: String; let hardcore: Bool?; let indexed: Bool? }; let economyLeagues: [L] }
        let data = try await get(URL(string: "https://poe.ninja/poe2/api/data/index-state")!)
        let s = try JSONDecoder().decode(S.self, from: data)
        if let l = s.economyLeagues.first(where: { $0.indexed == true && $0.hardcore != true }) { return l.name }
        if let l = s.economyLeagues.first(where: { $0.hardcore != true && $0.name != "Standard" }) { return l.name }
        throw PriceError.noData("poe.ninja has no current league")
    }

    public func lookup(name: String, baseType: String?, corrupted: Bool) -> NinjaPrice? {
        guard let hits = byName[TextUtil.normalize(name)], !hits.isEmpty else { return nil }
        var pool = hits
        if let b = baseType {
            let nb = TextUtil.normalize(b)
            let sameBase = pool.filter { $0.baseType.map(TextUtil.normalize) == nb }
            if !sameBase.isEmpty { pool = sameBase }
        }
        let sameCorruption = pool.filter { $0.corrupted == corrupted }
        if !sameCorruption.isEmpty { pool = sameCorruption }
        // Most-listed variant is the representative one.
        return pool.max { ($0.volume ?? 0) < ($1.volume ?? 0) }
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw PriceError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, url.absoluteString)
        }
        return data
    }

    private func fetchAll(league: String) async throws -> NinjaSnapshot {
        let q = league.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? league
        var prices: [NinjaPrice] = []
        var exPerDiv = 0.0, chaosPerDiv = 0.0
        var currencyById: [String: Double] = ["divine": 1]

        struct Exchange: Decodable {
            struct Core: Decodable { let rates: [String: Double]; let primary: String }
            struct Line: Decodable { let id: String; let primaryValue: Double; let volumePrimaryValue: Double? }
            struct Item: Decodable { let id: String; let name: String; let category: String? }
            let core: Core; let lines: [Line]; let items: [Item]
        }
        struct Stash: Decodable {
            struct Line: Decodable {
                let name: String; let baseType: String?; let primaryValue: Double
                let listingCount: Double?; let category: String?; let corrupted: Bool?
            }
            let lines: [Line]
        }

        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for t in Self.exchangeTypes {
                let url = URL(string: "https://poe.ninja/poe2/api/economy/exchange/current/overview?league=\(q)&type=\(t)")!
                group.addTask { ("x:" + t, try await self.get(url)) }
            }
            for t in Self.stashTypes {
                let url = URL(string: "https://poe.ninja/poe2/api/economy/stash/current/item/overview?league=\(q)&type=\(t)")!
                group.addTask { ("s:" + t, try await self.get(url)) }
            }
            for try await (key, data) in group {
                let type = String(key.dropFirst(2))
                if key.hasPrefix("x:") {
                    guard let x = try? JSONDecoder().decode(Exchange.self, from: data) else { continue }
                    if type == "Currency" {
                        exPerDiv = x.core.rates["exalted"] ?? exPerDiv
                        chaosPerDiv = x.core.rates["chaos"] ?? chaosPerDiv
                    }
                    let names = Dictionary(x.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    for l in x.lines {
                        guard let it = names[l.id] else { continue }
                        currencyById[l.id] = l.primaryValue
                        prices.append(NinjaPrice(name: it.name, baseType: nil, divine: l.primaryValue,
                                                 volume: l.volumePrimaryValue, category: type, corrupted: false))
                    }
                } else {
                    guard let s = try? JSONDecoder().decode(Stash.self, from: data) else { continue }
                    for l in s.lines {
                        prices.append(NinjaPrice(name: l.name, baseType: l.baseType, divine: l.primaryValue,
                                                 volume: l.listingCount, category: type, corrupted: l.corrupted ?? false))
                    }
                }
            }
        }
        guard !prices.isEmpty else { throw PriceError.noData("poe.ninja returned no prices for \(league)") }
        return NinjaSnapshot(league: league, fetched: Date(), exaltedPerDivine: exPerDiv, chaosPerDivine: chaosPerDiv,
                             prices: prices, currencyById: currencyById)
    }
}

public enum PriceError: LocalizedError {
    case http(Int, String)
    case noData(String)
    case rateLimited(TimeInterval)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case let .http(code, url): return "HTTP \(code) from \(URL(string: url)?.host ?? url)"
        case let .noData(s): return s
        case let .rateLimited(s): return "Trade API rate limit — wait \(Int(s.rounded(.up)))s"
        case let .api(s): return s
        }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
