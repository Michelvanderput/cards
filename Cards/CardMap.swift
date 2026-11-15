import Foundation

/// Koppeling van Cardmarket-ids naar setnamen en kaartafbeeldingen (bron: TCGdex).
/// Gegenereerd met Scripts/build_map.py en meegebundeld als Resources/cardmap.json.
struct CardMap {
    var sets: [Int: String] = [:]      // idExpansion -> setnaam
    var images: [Int: String] = [:]    // idProduct -> TCGdex-pad, bv. "en/base/base1/4"
    var setPaths: [Int: String] = [:]  // idExpansion -> TCGdex-setpad, bv. "en/base/base1" (voor het logo)
    var setDates: [String: Date] = [:] // setpad -> releasedatum
    var variants: [Int: String] = [:]  // idProduct -> variantlabel (leeg = gewone kaart)
    var main: Set<Int> = []            // expansions van de Engelse hoofdset (anderen zijn andere uitvoeringen)
    var exact: Set<Int> = []           // producten waarvan TCGdex het Cardmarket-id kent (betrouwbare koppeling)

    static let empty = CardMap()

    static func load() -> CardMap {
        guard let url = Bundle.main.url(forResource: "cardmap", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return .empty }
        return CardMap(
            sets: Dictionary(uniqueKeysWithValues: raw.sets.compactMap { k, v in Int(k).map { ($0, v) } }),
            images: Dictionary(uniqueKeysWithValues: raw.images.compactMap { k, v in Int(k).map { ($0, v) } }),
            setPaths: Dictionary(uniqueKeysWithValues: (raw.setPaths ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } }),
            setDates: (raw.setDates ?? [:]).compactMapValues { Self.dateFormatter.date(from: $0) },
            variants: Dictionary(uniqueKeysWithValues: (raw.variants ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } }),
            main: Set(raw.main ?? []),
            exact: Set(raw.exact ?? []))
    }

    private struct Raw: Decodable {
        let sets: [String: String]
        let images: [String: String]
        let exact: [Int]?
        let setPaths: [String: String]?
        let setDates: [String: String]?
        let variants: [String: String]?
        let main: [Int]?
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// TCGdex-kaart-id (bv. "base1-4") voor exact gekoppelde producten.
    func tcgdexCardID(for productID: Int) -> String? {
        guard exact.contains(productID), let parts = images[productID]?.split(separator: "/"), parts.count >= 4 else { return nil }
        return "\(parts[parts.count - 2])-\(parts[parts.count - 1])"
    }

    func releaseDate(expansion id: Int) -> Date? { setPaths[id].flatMap { setDates[$0] } }

    func setLogoURL(_ expansionID: Int) -> URL? {
        setPaths[expansionID].flatMap { URL(string: "https://assets.tcgdex.net/\($0)/logo.webp") }
    }

    enum Quality: String { case low, high }

    func imageURL(for productID: Int, quality: Quality) -> URL? {
        guard let path = images[productID] else { return nil }
        return URL(string: "https://assets.tcgdex.net/\(path)/\(quality.rawValue).webp")
    }
}
