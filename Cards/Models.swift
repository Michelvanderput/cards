import Foundation

struct PriceSet: Codable, Hashable {
    var avg: Double?
    var low: Double?
    var trend: Double?
    var avg1: Double?
    var avg7: Double?
    var avg30: Double?

    var isEmpty: Bool { [avg, low, trend, avg1, avg7, avg30].allSatisfy { $0 == nil } }
}

struct CardItem: Identifiable, Codable, Hashable {
    let id: Int          // Cardmarket idProduct
    let name: String
    let expansionId: Int
    var normal: PriceSet
    var holo: PriceSet

    /// Hoofdprijs: de Cardmarket-trendprijs (EUR).
    var mainPrice: Double? { normal.trend ?? holo.trend ?? normal.avg ?? holo.avg }

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
