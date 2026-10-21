import Foundation

public struct TradeListing: Sendable, Identifiable {
    public let id: String
    public let amount: Double
    public let currency: String
    public let indexed: Date?
    public let itemLevel: Int?
    public let seller: String?
    /// Price converted to Divine Orbs using poe.ninja rates, when known.
    public var divine: Double?
}

public struct TradeResult: Sendable {
    public let queryId: String
    public let total: Int
    public let listings: [TradeListing]
    public let search: RareSearch?
    public let league: String

    public var webURL: URL {
        let l = league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? league
        return URL(string: "https://www.pathofexile.com/trade2/search/poe2/\(l)/\(queryId)")!
    }
}

/// Official PoE 2 trade API (pathofexile.com/api/trade2), rate limited per GGG headers.
public actor TradeClient {
    private let session: URLSession
    private let userAgent: String
    public let limiter = RateLimiter(defaults: [
        "trade-search-request-limit": "5:10:60,15:60:300,30:300:1800",
        "trade-fetch-request-limit": "12:4:10,16:12:300",
    ])
    private static let base = "https://www.pathofexile.com/api/trade2"

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    public func leagues() async throws -> [String] {
        struct R: Decodable { struct L: Decodable { let id: String; let realm: String? }; let result: [L] }
        let (data, _) = try await request(URL(string: "\(Self.base)/data/leagues")!, policy: nil)
        return try JSONDecoder().decode(R.self, from: data).result.filter { ($0.realm ?? "poe2") == "poe2" }.map(\.id)
    }

    /// Runs `search`, auto-relaxing (when allowed) until at least `target` results or nothing left to relax.
    public func price(_ search: RareSearch, league: String, autoRelax: Bool, target: Int = 10, maxSearches: Int = 4,
                      currencyRates: [String: Double]) async throws -> TradeResult {
        var current = search
        var searches = 0
        while true {
            let (id, total, ids) = try await runSearch(current, league: league)
            searches += 1
            if autoRelax, total < target, searches < maxSearches, let next = current.relaxed() {
                current = next
                continue
            }
            let listings = try await fetch(Array(ids.prefix(10)), queryId: id, rates: currencyRates)
            return TradeResult(queryId: id, total: total, listings: listings, search: current, league: league)
        }
    }

    /// Plain search by unique name / base type (uniques, gems, anything poe.ninja lacks).
    public func priceByName(name: String?, type: String?, gemLevel: Int?, corrupted: Bool, league: String,
                            status: String, currencyRates: [String: Double]) async throws -> TradeResult {
        var misc: [String: Any] = ["corrupted": ["option": corrupted ? "true" : "false"]]
        if let g = gemLevel { misc["gem_level"] = ["min": g] }
        var query: [String: Any] = ["status": ["option": status], "stats": [["type": "and", "filters": []]],
                                    "filters": ["misc_filters": ["filters": misc]]]
        if let name { query["name"] = name }
        if let type { query["type"] = type }
        let (id, total, ids) = try await runSearch(["query": query, "sort": ["price": "asc"]], league: league)
        let listings = try await fetch(Array(ids.prefix(10)), queryId: id, rates: currencyRates)
        return TradeResult(queryId: id, total: total, listings: listings, search: nil, league: league)
    }

    func runSearch(_ search: RareSearch, league: String) async throws -> (String, Int, [String]) {
        try await runSearch(search.queryJSON(), league: league)
    }

    func runSearch(_ json: [String: Any], league: String) async throws -> (String, Int, [String]) {
        let l = league.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? league
        let body = try JSONSerialization.data(withJSONObject: json)
        let (data, _) = try await request(URL(string: "\(Self.base)/search/poe2/\(l)")!, policy: "trade-search-request-limit", body: body)
        struct R: Decodable { let id: String; let total: Int?; let result: [String] }
        let r = try JSONDecoder().decode(R.self, from: data)
        return (r.id, r.total ?? r.result.count, r.result)
    }

    func fetch(_ ids: [String], queryId: String, rates: [String: Double]) async throws -> [TradeListing] {
        guard !ids.isEmpty else { return [] }
        let url = URL(string: "\(Self.base)/fetch/\(ids.joined(separator: ","))?query=\(queryId)&realm=poe2")!
        let (data, _) = try await request(url, policy: "trade-fetch-request-limit")
        struct R: Decodable {
            struct Entry: Decodable {
                struct Listing: Decodable {
                    struct Price: Decodable { let amount: Double; let currency: String }
                    struct Account: Decodable { let name: String? }
                    let indexed: String?; let price: Price?; let account: Account?
                }
                struct Item: Decodable { let ilvl: Int? }
                let id: String; let listing: Listing; let item: Item?
            }
            let result: [Entry?]
        }
        let iso = ISO8601DateFormatter()
        return try JSONDecoder().decode(R.self, from: data).result.compactMap { e in
            guard let e, let p = e.listing.price else { return nil }
            return TradeListing(id: e.id, amount: p.amount, currency: p.currency,
                                indexed: e.listing.indexed.flatMap { iso.date(from: $0) },
                                itemLevel: e.item?.ilvl, seller: e.listing.account?.name,
                                divine: rates[p.currency].map { $0 * p.amount })
        }
    }

    private func request(_ url: URL, policy: String?, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        if let policy {
            let blocked = await limiter.secondsBlocked(policy)
            if blocked > 15 { throw PriceError.rateLimited(blocked) }
            try await limiter.acquire(policy)
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        if let body {
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PriceError.api("No response") }
        if let policy { await limiter.update(policy, headers: http.allHeaderFields, status: http.statusCode) }
        if http.statusCode == 429 {
            throw PriceError.rateLimited(await limiter.secondsBlocked(policy ?? ""))
        }
        guard http.statusCode == 200 else {
            struct E: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
            if let e = try? JSONDecoder().decode(E.self, from: data) { throw PriceError.api("Trade API: \(e.error.message)") }
            throw PriceError.http(http.statusCode, url.absoluteString)
        }
        return (data, http)
    }
}
