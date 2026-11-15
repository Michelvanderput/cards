import Foundation
import Observation

/// Haalt de openbare Cardmarket-bestanden (productlijst + price guide voor Pokémon, idGame 6)
/// op en voegt ze samen. De bestanden worden dagelijks door Cardmarket ververst.
@MainActor
@Observable
final class CatalogStore {
    private(set) var items: [CardItem] = []
    private(set) var byID: [Int: CardItem] = [:]
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false
    var errorMessage: String?
    let map = CardMap.load()
    private var searchIndex: [String] = []

    func setName(for item: CardItem) -> String? { map.sets[item.expansionId] }
    func imageURL(for item: CardItem, quality: CardMap.Quality) -> URL? { map.imageURL(for: item.id, quality: quality) }

    static let maxAge: TimeInterval = 6 * 3600
    private static let productsURL = URL(string: "https://downloads.s3.cardmarket.com/productCatalog/productList/products_singles_6.json")!
    private static let guideURL = URL(string: "https://downloads.s3.cardmarket.com/productCatalog/priceGuide/price_guide_6.json")!

    /// Laadt de cache en ververst als die verouderd is.
    func start() async {
        if items.isEmpty, let snap = await Task.detached(operation: { Self.readCache() }).value {
            apply(snap)
        }
        if let last = lastUpdated, Date().timeIntervalSince(last) < Self.maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await Task.detached(operation: { try await Self.download() }).value
            apply(snap)
            errorMessage = nil
        } catch {
            errorMessage = "Verversen mislukt: \(error.localizedDescription)"
        }
    }

    func search(_ query: String, limit: Int = 300) -> [CardItem] {
        var out = searchAll(query)
        out.sort { ($0.mainPrice ?? -1) > ($1.mainPrice ?? -1) }
        return Array(out.prefix(limit))
    }

    /// Alle treffers, ongesorteerd (filteren en sorteren doet de view).
    func searchAll(_ query: String) -> [CardItem] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var out: [CardItem] = []
        for (i, haystack) in searchIndex.enumerated() where tokens.allSatisfy({ haystack.contains($0) }) {
            out.append(items[i])
        }
        return out
    }

    private func apply(_ snap: Snapshot) {
        items = snap.items
        byID = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.id, $0) })
        lastUpdated = snap.fetchedAt
        searchIndex = snap.items.map { ($0.name + " " + (map.sets[$0.expansionId] ?? "")).lowercased() }
    }

    // MARK: - Netwerk & cache (buiten de main actor)

    nonisolated private static func download() async throws -> Snapshot {
        async let p = URLSession.shared.data(from: productsURL)
        async let g = URLSession.shared.data(from: guideURL)
        let (pData, gData) = try await (p.0, g.0)
        let products = try JSONDecoder().decode(RawProducts.self, from: pData).products
        let guides = try JSONDecoder().decode(RawGuides.self, from: gData).priceGuides
        let guideByID = Dictionary(guides.map { ($0.idProduct, $0) }, uniquingKeysWith: { a, _ in a })

        let items: [CardItem] = products.map { p in
            let g = guideByID[p.idProduct]
            return CardItem(
                id: p.idProduct, name: p.name, expansionId: p.idExpansion,
                normal: PriceSet(avg: g?.avg, low: g?.low, trend: g?.trend, avg1: g?.avg1, avg7: g?.avg7, avg30: g?.avg30),
                holo: PriceSet(avg: g?.avgHolo, low: g?.lowHolo, trend: g?.trendHolo, avg1: g?.avg1Holo, avg7: g?.avg7Holo, avg30: g?.avg30Holo))
        }
        let snap = Snapshot(fetchedAt: Date(), items: items)
        writeCache(snap)
        return snap
    }

    nonisolated private static var cacheURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "snapshot.json")
    }

    nonisolated private static func readCache() -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    nonisolated private static func writeCache(_ snap: Snapshot) {
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
