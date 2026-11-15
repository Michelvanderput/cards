import Foundation

/// Koppeling van Cardmarket-ids naar setnamen en kaartafbeeldingen (bron: TCGdex).
/// Gegenereerd met Scripts/build_map.py en meegebundeld als Resources/cardmap.json.
struct CardMap {
    var sets: [Int: String] = [:]      // idExpansion -> setnaam
    var images: [Int: String] = [:]    // idProduct -> TCGdex-pad, bv. "en/base/base1/4"

    static let empty = CardMap()

    static func load() -> CardMap {
        guard let url = Bundle.main.url(forResource: "cardmap", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return .empty }
        return CardMap(
            sets: Dictionary(uniqueKeysWithValues: raw.sets.compactMap { k, v in Int(k).map { ($0, v) } }),
            images: Dictionary(uniqueKeysWithValues: raw.images.compactMap { k, v in Int(k).map { ($0, v) } }))
    }

    private struct Raw: Decodable {
        let sets: [String: String]
        let images: [String: String]
    }

    enum Quality: String { case low, high }

    func imageURL(for productID: Int, quality: Quality) -> URL? {
        guard let path = images[productID] else { return nil }
        return URL(string: "https://assets.tcgdex.net/\(path)/\(quality.rawValue).webp")
    }
}
