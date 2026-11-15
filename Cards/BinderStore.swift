import Foundation
import Observation

/// Een binder met pagina's van rows × columns vakjes. Elk vakje bevat een kaart (Cardmarket idProduct) of is leeg.
struct Binder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int = 0
    var columns: Int = 3
    var rows: Int = 3
    var pages: Int = 4
    var slots: [Int?]

    var slotsPerPage: Int { columns * rows }
    var filled: Int { slots.compactMap { $0 }.count }

    init(name: String, colorIndex: Int, columns: Int = 3, rows: Int = 3, pages: Int = 4) {
        self.name = name
        self.colorIndex = colorIndex
        self.columns = columns
        self.rows = rows
        self.pages = pages
        self.slots = Array(repeating: nil, count: columns * rows * pages)
    }
}

@MainActor
@Observable
final class BinderStore {
    private(set) var binders: [Binder] = []

    init() { load() }

    func binder(_ id: UUID) -> Binder? { binders.first { $0.id == id } }

    func add(name: String, colorIndex: Int, columns: Int, rows: Int, pages: Int) -> Binder {
        let b = Binder(name: name, colorIndex: colorIndex, columns: columns, rows: rows, pages: pages)
        binders.append(b)
        save()
        return b
    }

    func remove(_ id: UUID) { binders.removeAll { $0.id == id }; save() }

    func rename(_ id: UUID, name: String, colorIndex: Int) {
        mutate(id) { $0.name = name; $0.colorIndex = colorIndex }
    }

    func setSlot(_ id: UUID, index: Int, productID: Int?) {
        mutate(id) { if $0.slots.indices.contains(index) { $0.slots[index] = productID } }
    }

    func swap(_ id: UUID, _ a: Int, _ b: Int) {
        mutate(id) { if $0.slots.indices.contains(a) && $0.slots.indices.contains(b) { $0.slots.swapAt(a, b) } }
    }

    func addPage(_ id: UUID) {
        mutate(id) { $0.pages += 1; $0.slots += Array(repeating: nil, count: $0.slotsPerPage) }
    }

    /// Zet de kaart in het eerste lege vakje. Geeft false terug als de binder vol is.
    @discardableResult
    func addCard(_ id: UUID, productID: Int) -> Bool {
        guard let b = binder(id), let i = b.slots.firstIndex(where: { $0 == nil }) else { return false }
        setSlot(id, index: i, productID: productID)
        return true
    }

    func value(_ b: Binder, catalog: CatalogStore) -> Double {
        b.slots.compactMap { $0 }.reduce(0) { $0 + (catalog.byID[$1]?.mainPrice ?? 0) }
    }

    private func mutate(_ id: UUID, _ change: (inout Binder) -> Void) {
        guard let i = binders.firstIndex(where: { $0.id == id }) else { return }
        change(&binders[i])
        save()
    }

    // MARK: - Opslag

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "binders.json")
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Binder].self, from: data) { binders = decoded }
    }

    func reload() { load() }

    private func save() {
        if let data = try? JSONEncoder().encode(binders) { try? data.write(to: fileURL, options: .atomic) }
        CloudSync.shared.localChanged("binders.json")
    }
}
