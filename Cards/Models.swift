import Foundation

struct PriceSet: Codable, Hashable {
    var avg: Double?
    var low: Double?
    var trend: Double?
    var avg1: Double?
    var avg7: Double?
    var avg30: Double?

    /// Trend, of bij een onwaarschijnlijke trend (minder dan 25% of meer dan 4× het gemiddelde) dat gemiddelde.
    var saneTrend: (value: Double?, uncertain: Bool) {
        guard let t = trend else { return (nil, false) }
        guard let ref = avg7 ?? avg30 ?? avg, ref > 0 else { return (t, false) }
        return (t >= 0.25 * ref && t <= 4 * ref) ? (t, false) : (ref, true)
    }

    var isEmpty: Bool { [avg, low, trend, avg1, avg7, avg30].allSatisfy { $0 == nil } }
}

struct CardItem: Identifiable, Codable, Hashable {
    let id: Int          // Cardmarket idProduct
    let name: String
    let expansionId: Int
    var metaID: Int?          // Cardmarket idMetacard: dezelfde kaart, ook als er meerdere producten (varianten) zijn
    var normal: PriceSet
    var holo: PriceSet

    /// Hoofdprijs: de Cardmarket-trendprijs (EUR), tenzij die niet in verhouding staat tot het 7-daags gemiddelde.
    /// De prijsgids bevat soms een onzinnige trend (bijv. €0,02 bij een gemiddelde van €47); dan gebruiken we het gemiddelde.
    var mainPrice: Double? {
        if normal.trend != nil { return normal.saneTrend.value }
        if holo.trend != nil { return holo.saneTrend.value }
        return normal.avg ?? holo.avg
    }

    /// De trendprijs wijkt sterk af van het gemiddelde; de getoonde prijs is dan het 7-daags gemiddelde.
    var priceIsUncertain: Bool {
        (normal.trend != nil ? normal.saneTrend.uncertain : holo.saneTrend.uncertain)
    }

    /// Prijsverandering: trend t.o.v. het 7-daags gemiddelde (positief = gestegen).
    var weekChange: Double? {
        for set in [normal, holo] {
            if let t = set.trend, let a = set.avg7, a > 0 { return t / a - 1 }
        }
        return nil
    }

    var cardmarketURL: URL {
        URL(string: "https://www.cardmarket.com/en/Pokemon/Products?idProduct=\(id)")!
    }
}

struct Snapshot: Codable {
    var fetchedAt: Date
    var items: [CardItem]
}

// MARK: - Ruwe Cardmarket-downloads

struct RawProducts: Decodable {
    struct Product: Decodable {
        let idProduct: Int
        let name: String
        let idExpansion: Int
        let idMetacard: Int?
    }
    let products: [Product]
}

struct RawGuides: Decodable {
    struct Guide: Decodable {
        let idProduct: Int
        let avg, low, trend, avg1, avg7, avg30: Double?
        let avgHolo, lowHolo, trendHolo, avg1Holo, avg7Holo, avg30Holo: Double?

        enum CodingKeys: String, CodingKey {
            case idProduct, avg, low, trend, avg1, avg7, avg30
            case avgHolo = "avg-holo", lowHolo = "low-holo", trendHolo = "trend-holo"
            case avg1Holo = "avg1-holo", avg7Holo = "avg7-holo", avg30Holo = "avg30-holo"
        }
    }
    let priceGuides: [Guide]
}
