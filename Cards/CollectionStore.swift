import Foundation
import Observation

/// Eén kaart (of stapel gelijke kaarten) in je collectie.
struct CollectionEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var productID: Int
    var name: String
    var condition: Condition = .nm
    var quantity: Int = 1
    var paidPrice: Double?      // wat je per kaart betaald hebt
    var myPrice: Double?        // jouw eigen waardering per kaart
    var note: String = ""
    var added = Date()
}

@MainActor
@Observable
final class CollectionStore {
    private(set) var entries: [CollectionEntry] = []

    init() { load() }

    func add(_ entry: CollectionEntry) { entries.append(entry); save() }

    func update(_ entry: CollectionEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i] = entry
        save()
    }

    func remove(_ id: UUID) { entries.removeAll { $0.id == id }; save() }

    func entries(for productID: Int) -> [CollectionEntry] { entries.filter { $0.productID == productID } }
    func count(of productID: Int) -> Int { entries(for: productID).reduce(0) { $0 + $1.quantity } }

    /// Waarde per kaart: jouw prijs, anders de Cardmarket-trend (schatting).
    func unitValue(_ e: CollectionEntry, catalog: CatalogStore) -> Double? {
        e.myPrice ?? catalog.byID[e.productID]?.mainPrice
    }

    func totalValue(catalog: CatalogStore) -> Double {
        entries.reduce(0) { $0 + (unitValue($1, catalog: catalog) ?? 0) * Double($1.quantity) }
    }

    var totalPaid: Double { entries.reduce(0) { $0 + ($1.paidPrice ?? 0) * Double($1.quantity) } }
    var totalCards: Int { entries.reduce(0) { $0 + $1.quantity } }

    // MARK: - Opslag

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "collection.json")
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([CollectionEntry].self, from: data) { entries = decoded }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
