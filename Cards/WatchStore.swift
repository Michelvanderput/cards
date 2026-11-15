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
    /// Gezet = alert op de goedkoopste aanbieding in deze staat of beter (via de aanbiedingen-pagina).
    /// Leeg = alert op de Cardmarket-trendprijs over alle staten.
    var minCondition: Condition?
    var lastCheapest: Double?
    var lastChecked: Date?
    /// Meld ook koopjes (dealscore 80+) op deze kaart, los van een doelprijs.
    var dealAlert: Bool?
    var lastDealSignature: String?

    var alertSummary: String? {
        guard let target else { return dealAlert == true ? "Meld koopjes" : nil }
        if let minCondition { return "\(minCondition.rawValue)+ onder \(euro(target))" }
        return "Trend \(direction.label.lowercased()) \(euro(target))"
    }
}

@MainActor
@Observable
final class WatchStore {
    private(set) var entries: [WatchEntry] = []

    init() { load() }

    var conditionEntries: [WatchEntry] {
        entries.filter { ($0.minCondition != nil && $0.target != nil) || $0.dealAlert == true }
    }

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

    func setAlert(_ id: Int, target: Double?, direction: AlertDirection, minCondition: Condition?, dealAlert: Bool = false) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].target = target
        entries[i].direction = minCondition == nil ? direction : .below
        entries[i].minCondition = minCondition
        entries[i].dealAlert = dealAlert
        entries[i].lastDealSignature = nil
        entries[i].alerted = false
        entries[i].lastCheapest = nil
        entries[i].lastChecked = nil
        save()
        if target != nil || dealAlert { Task { await Self.requestPermission() } }
    }

    /// Controleert de trend-alerts (alle staten) tegen de nieuwste prijsbestanden.
    func evaluate(catalog: CatalogStore) async {
        var changed = false
        for i in entries.indices where entries[i].minCondition == nil {
            let e = entries[i]
            guard let target = e.target, let price = catalog.byID[e.id]?.mainPrice else { continue }
            let met = e.direction == .below ? price <= target : price >= target
            if met && !e.alerted {
                await Self.notify(title: e.name,
                                  body: "Trendprijs is nu \(euro(price)) (\(e.direction.label.lowercased()) \(euro(target)))")
                entries[i].alerted = true
                changed = true
            } else if !met && e.alerted {
                entries[i].alerted = false
                changed = true
            }
        }
        if changed { save() }
    }

    /// Verwerkt de goedkoopste aanbieding (staat of beter) voor een alert per staat.
    func applyConditionResult(id: Int, cheapest: Double?) async {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].lastCheapest = cheapest
        entries[i].lastChecked = Date()
        defer { save() }
        guard let target = entries[i].target, let cond = entries[i].minCondition, let cheapest else { return }
        let met = cheapest <= target
        if met && !entries[i].alerted {
            await Self.notify(title: entries[i].name,
                              body: "\(cond.rawValue)+ vanaf \(euro(cheapest)) (je alert: onder \(euro(target)))")
            entries[i].alerted = true
        } else if !met && entries[i].alerted {
            entries[i].alerted = false
        }
    }

    /// Meldt een koopje (eenmalig per aanbieding).
    func applyDeal(id: Int, signature: String, body: String) async {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].lastDealSignature != signature else { return }
        entries[i].lastDealSignature = signature
        save()
        await Self.notify(title: "Koopje: \(entries[i].name)", body: body)
    }

    // MARK: - Notificaties

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notify(title: String, body: String) async {
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
