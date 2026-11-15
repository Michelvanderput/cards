import Foundation
import Observation
import UserNotifications

enum AlertDirection: String, Codable, CaseIterable, Identifiable {
    case below, above
    var id: String { rawValue }
    var label: String { self == .below ? "Onder" : "Boven" }
}

struct WatchEntry: Identifiable, Codable, Hashable {
    let id: Int              // Cardmarket idProduct
    var name: String
    var target: Double?
    var direction: AlertDirection = .below
    var alerted: Bool = false
}

@MainActor
@Observable
final class WatchStore {
    private(set) var entries: [WatchEntry] = []

    init() { load() }

    func isWatching(_ id: Int) -> Bool { entries.contains { $0.id == id } }
    func entry(_ id: Int) -> WatchEntry? { entries.first { $0.id == id } }

    func add(_ item: CardItem) {
        guard !isWatching(item.id) else { return }
        entries.append(WatchEntry(id: item.id, name: item.name))
        save()
    }

    func remove(_ id: Int) {
        entries.removeAll { $0.id == id }
        save()
    }

    func setAlert(_ id: Int, target: Double?, direction: AlertDirection) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].target = target
        entries[i].direction = direction
        entries[i].alerted = false
        save()
        if target != nil { Task { await Self.requestPermission() } }
    }

    /// Controleert alle prijsalerts tegen de nieuwste prijzen en stuurt notificaties.
    func evaluate(catalog: CatalogStore) async {
        var changed = false
        for i in entries.indices {
            let e = entries[i]
            guard let target = e.target, let price = catalog.byID[e.id]?.mainPrice else { continue }
            let met = e.direction == .below ? price <= target : price >= target
            if met && !e.alerted {
                await Self.notify(title: e.name,
                                  body: "Prijs is nu \(price.formatted(.currency(code: "EUR"))) (\(e.direction.label.lowercased()) \(target.formatted(.currency(code: "EUR"))))")
                entries[i].alerted = true
                changed = true
            } else if !met && e.alerted {
                entries[i].alerted = false
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Notificaties

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private static func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Opslag

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "watchlist.json")
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
