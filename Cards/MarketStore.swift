import Foundation
import Observation

/// Statistieken van de geladen aanbiedingen (goedkoopste ~200) voor één filter.
struct ListingStats: Codable, Hashable {
    var min: Double
    var p25: Double      // prijs waarmee je de goedkoopste 25% van de aanbiedingen verslaat
    var median: Double
    var count: Int
    var updated: Date
}

struct MarketInfo: Codable {
    var tcgplayerUSD: Double?
    var tcgFetched: Date?
    /// Sleutel = "ALL" of een staat ("NM" = NM of beter), afhankelijk van het gebruikte filter.
    var stats: [String: ListingStats] = [:]
}

/// Bewaart marktdata per kaart: TCGplayer-prijs (via TCGdex, USD→EUR) en statistieken van Cardmarket-aanbiedingen.
@MainActor
@Observable
final class MarketStore {
    private(set) var info: [Int: MarketInfo] = [:]
    private(set) var usdToEur: Double?
    private var fxFetched: Date?
    private let storage: URL?

    /// - Parameter storage: map voor het opslagbestand (alleen voor tests); standaard de app-map.
    init(storage: URL? = nil) { self.storage = storage; load() }

    func tcgplayerEUR(_ id: Int) -> Double? {
        guard let usd = info[id]?.tcgplayerUSD, let fx = usdToEur else { return nil }
        return usd * fx
    }

    func stats(_ id: Int, minCondition: Condition?) -> ListingStats? {
        info[id]?.stats[minCondition?.rawValue ?? "ALL"]
    }

    func recordListings(id: Int, minCondition: Condition?, listings: [Listing]) {
        let prices = listings.map(\.price).sorted()
        guard prices.count >= 4 else { return }
        var entry = info[id] ?? MarketInfo()
        entry.stats[minCondition?.rawValue ?? "ALL"] = ListingStats(
            min: prices[0], p25: DealAnalyzer.percentile(prices, 0.25), median: DealAnalyzer.percentile(prices, 0.5),
            count: prices.count, updated: Date())
        info[id] = entry
        save()
    }

    /// Haalt de TCGplayer-marktprijs voor deze kaartvariant op (alleen bij exacte koppeling) en ververst de wisselkoers.
    func fetchCrossMarket(item: CardItem, map: CardMap) async {
        await refreshFX()
        guard let cardID = map.tcgdexCardID(for: item.id) else { return }
        if let t = info[item.id]?.tcgFetched, Date().timeIntervalSince(t) < 12 * 3600 { return }
        guard let url = URL(string: "https://api.tcgdex.net/v2/en/cards/\(cardID)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let variants = json["variants_detailed"] as? [[String: Any]] else { return }
        var usd: Double?
        for v in variants {
            let pricing = v["pricing"] as? [String: Any]
            let cmID = (pricing?["cardmarket"] as? [String: Any])?["idProduct"] as? Int
            let tp = (v["thirdParty"] as? [String: Any])?["cardmarket"] as? Int
            guard cmID == item.id || tp == item.id, let tcg = pricing?["tcgplayer"] as? [String: Any] else { continue }
            for (key, value) in tcg where key != "unit" && key != "updated" {
                if let d = value as? [String: Any], let m = d["marketPrice"] as? Double { usd = m; break }
            }
        }
        var entry = info[item.id] ?? MarketInfo()
        entry.tcgplayerUSD = usd
        entry.tcgFetched = Date()
        info[item.id] = entry
        save()
    }

    private func refreshFX() async {
        if let t = fxFetched, Date().timeIntervalSince(t) < 24 * 3600, usdToEur != nil { return }
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = (json["rates"] as? [String: Double])?["EUR"] else { return }
        usdToEur = rate
        fxFetched = Date()
    }

    // MARK: - Opslag

    private var fileURL: URL {
        let dir = storage ?? URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "market.json")
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Int: MarketInfo].self, from: data) { info = decoded }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: fileURL, options: .atomic) }
    }
}
