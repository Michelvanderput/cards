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
    private(set) var map = CardMap.load()
    private var searchIndex: [String] = []
    private(set) var sets: [SetInfo] = []
    private(set) var itemsBySet: [Int: [CardItem]] = [:]   // SetInfo.id -> alle producten (alle samengevoegde delen)
    private(set) var repsBySet: [Int: [CardItem]] = [:]     // SetInfo.id -> één product per echte kaart
    private var setIDByExpansion: [Int: Int] = [:]
    private var variantsByKey: [String: [CardItem]] = [:]
    private var repByKey: [String: CardItem] = [:]
    private var versionLabels: [Int: String] = [:]   // idProduct -> "V.1", "V.2" bij producten met dezelfde naam

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
        if let last = lastUpdated, Date().timeIntervalSince(last) < Self.maxAge, items.first?.metaID != nil { return }
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

    /// Voor tests: laadt een catalogus met een eigen koppelbestand.
    func load(snapshot: Snapshot, map: CardMap) {
        self.map = map
        apply(snapshot)
    }

    /// Voegt Cardmarket-delen van dezelfde Engelse set samen. Andere uitvoeringen (Japans e.d.) blijven apart,
    /// en producten die dezelfde kaart zijn (varianten) worden gegroepeerd tot één kaart.
    private func buildSets(_ all: [CardItem]) {
        let byExp = Dictionary(grouping: all, by: \.expansionId)
        var groups: [String: [Int]] = [:]
        for exp in byExp.keys {
            let key: String
            if let name = map.sets[exp] { key = (map.main.isEmpty || map.main.contains(exp)) ? "n:" + name : "o:" + name }
            else { key = "e:\(exp)" }
            groups[key, default: []].append(exp)
        }
        var built: [SetInfo] = []
        var bySet: [Int: [CardItem]] = [:]
        var repsBySet: [Int: [CardItem]] = [:]
        var setIDs: [Int: Int] = [:]
        for (key, exps) in groups {
            let ids = exps.sorted()
            let id = ids[0]
            ids.forEach { setIDs[$0] = id }
            bySet[id] = ids.flatMap { byExp[$0] ?? [] }
        }
        setIDByExpansion = setIDs

        // Producten die dezelfde fysieke kaart zijn (zelfde TCGdex-kaart, bv. normaal en reverse holo) groeperen we.
        // Producten zonder betrouwbare koppeling blijven los; heten ze hetzelfde, dan krijgen ze V.1, V.2 (zoals Cardmarket).
        var variants: [String: [CardItem]] = [:]
        for item in all {
            guard let key = groupKey(item, setIDs: setIDs) else { continue }
            variants[key, default: []].append(item)
        }
        var reps: [String: CardItem] = [:]
        for (key, list) in variants {
            reps[key] = list.min { (isStandard($0) ? 0 : 1, $0.id) < (isStandard($1) ? 0 : 1, $1.id) }!
        }
        variantsByKey = variants
        repByKey = reps

        var versions: [Int: String] = [:]
        for (id, items) in bySet {
            _ = id
            let loose = items.filter { groupKey($0, setIDs: setIDs) == nil }
            for (_, same) in Dictionary(grouping: loose, by: \.name) where same.count > 1 {
                for (i, item) in same.sorted(by: { $0.id < $1.id }).enumerated() { versions[item.id] = "V.\(i + 1)" }
            }
        }
        versionLabels = versions

        for (key, exps) in groups {
            let ids = exps.sorted()
            let id = ids[0]
            let items = bySet[id] ?? []
            let rs = collapse(items)
            repsBySet[id] = rs
            let name = map.sets[id]
            let isMain = !key.hasPrefix("o:")
            built.append(SetInfo(id: id, expansionIDs: ids,
                                 name: name.map { isMain ? $0 : $0 + " (andere uitvoering)" } ?? "Set \(id)",
                                 isNamed: name != nil, isMain: isMain, count: items.count, cardCount: rs.count,
                                 logoURL: ids.lazy.compactMap { self.map.setLogoURL($0) }.first,
                                 releaseDate: ids.lazy.compactMap { self.map.releaseDate(expansion: $0) }.first ?? Self.yearInName(name)))
        }
        sets = built
        itemsBySet = bySet
        self.repsBySet = repsBySet
    }

    private func isStandard(_ item: CardItem) -> Bool { (map.variants[item.id] ?? "").isEmpty }

    /// Sleutel van de fysieke kaart (alleen bij betrouwbaar gekoppelde producten); anders nil.
    private func groupKey(_ item: CardItem, setIDs: [Int: Int]? = nil) -> String? {
        guard map.exact.contains(item.id), let path = map.images[item.id],
              let sid = (setIDs ?? setIDByExpansion)[item.expansionId] else { return nil }
        return "\(sid)|\(path)"
    }

    /// Kaartnummer binnen de set, bijvoorbeeld "#4" (alleen bij betrouwbaar gekoppelde producten).
    func cardNumber(for item: CardItem) -> String? {
        guard map.exact.contains(item.id), let last = map.images[item.id]?.split(separator: "/").last else { return nil }
        return "#\(last)"
    }

    /// Alle uitvoeringen van dezelfde kaart in dezelfde set (inclusief het item zelf).
    func variants(of item: CardItem) -> [CardItem] {
        groupKey(item).flatMap { variantsByKey[$0] }?.sorted { $0.id < $1.id } ?? [item]
    }

    /// Heb je deze kaart (in welke uitvoering dan ook) al?
    func isOwned(_ item: CardItem, ownedIDs: Set<Int>) -> Bool {
        variants(of: item).contains { ownedIDs.contains($0.id) }
    }

    /// Kaarten van een set: één per echte kaart, of alle Cardmarket-producten.
    func cards(in set: SetInfo, grouped: Bool) -> [CardItem] {
        (grouped ? repsBySet[set.id] : itemsBySet[set.id]) ?? []
    }

    /// Variantlabel zoals "Reverse holo" of "1e editie"; nil voor de gewone kaart.
    func variantLabel(for item: CardItem) -> String? {
        let label = map.variants[item.id] ?? ""
        return label.isEmpty ? versionLabels[item.id] : label
    }

    /// Eén kaart per echte kaart (dezelfde set en idMetacard), op volgorde van eerste voorkomen.
    func collapse(_ list: [CardItem]) -> [CardItem] {
        var seen = Set<String>()
        var out: [CardItem] = []
        for item in list {
            guard let key = groupKey(item) else { out.append(item); continue }
            if seen.insert(key).inserted, let rep = repByKey[key] { out.append(rep) }
        }
        return out
    }

    /// Terugval voor sets zonder datum: een jaartal in de naam ("McDonald's Collection 2012") als 1 januari van dat jaar.
    nonisolated private static func yearInName(_ name: String?) -> Date? {
        guard let name, let r = name.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression),
              let year = Int(name[r]) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1))
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
        buildSets(snap.items)
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
                id: p.idProduct, name: p.name, expansionId: p.idExpansion, metaID: p.idMetacard,
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

struct SetInfo: Identifiable, Hashable {
    let id: Int          // laagste Cardmarket idExpansion van de samengevoegde delen
    let expansionIDs: [Int]
    let name: String
    let isNamed: Bool
    let isMain: Bool     // Engelse hoofdset; anders een andere uitvoering
    let count: Int       // aantal Cardmarket-producten
    let cardCount: Int   // aantal echte kaarten (varianten samengevoegd)
    let logoURL: URL?
    let releaseDate: Date?
}
