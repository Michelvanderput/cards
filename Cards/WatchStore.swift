import Foundation
import Observation
import UserNotifications

enum AlertDirection: String, Codable, CaseIterable, Identifiable {
    case below, above
    var id: String { rawValue }
    var label: String { self == .below ? "Onder" : "Boven" }
}

/// Eén melding. Dezelfde `key` vervangt een eerdere melding in plaats van te stapelen; `thread` groepeert per kaart.
struct Notice: Equatable {
    let key: String
    let thread: String
    let title: String
    let body: String
}

extension String {
    /// Kaartnaam zonder aanvallen: "Mewtwo ex [Psyburn | ...]" wordt "Mewtwo ex".
    var cleanCardName: String {
        (split(separator: "[", maxSplits: 1).first.map(String.init) ?? self).trimmingCharacters(in: .whitespaces)
    }
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
    var lastDealPrice: Double?
    var lastDealDate: Date?

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
    private let storage: URL?

    /// Verstuurt een melding. In tests vervangen door een recorder.
    @ObservationIgnored var notifier: (Notice) async -> Void = { notice in
        await WatchStore.notify(notice)
    }

    /// - Parameter storage: map voor het opslagbestand (alleen voor tests); standaard de app-map.
    init(storage: URL? = nil) {
        self.storage = storage
        load()
    }

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

    func remove(_ id: Int) { remove(ids: [id]) }

    func remove(ids: Set<Int>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Verwijdert alleen de alert van een kaart; de kaart blijft op de watchlist.
    func clearAlert(_ id: Int) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].target = nil
        entries[i].minCondition = nil
        entries[i].dealAlert = nil
        entries[i].alerted = false
        entries[i].lastCheapest = nil
        entries[i].lastChecked = nil
        entries[i].lastDealSignature = nil
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
    }

    /// Controleert de trend-alerts (alle staten) tegen de nieuwste prijzen en meldt de alerts die gehaald worden.
    /// Geeft het aantal verstuurde meldingen terug.
    @discardableResult
    func evaluate(catalog: CatalogStore) async -> Int {
        var sent = 0
        // Werk met id's, niet met posities: tijdens het wachten op een melding kan de lijst veranderen.
        for id in entries.filter({ $0.minCondition == nil && $0.target != nil }).map(\.id) {
            guard let i = entries.firstIndex(where: { $0.id == id }) else { continue }
            let e = entries[i]
            guard let target = e.target, let price = catalog.byID[id]?.mainPrice else { continue }
            let met = e.direction == .below ? price <= target : price >= target
            if met && !e.alerted {
                // Eerst markeren, dan melden: een tweede controle tijdens het versturen geeft zo geen dubbele melding.
                entries[i].alerted = true
                save()
                await notifier(Notice(key: "trend-\(id)", thread: "card-\(id)", title: e.name.cleanCardName,
                                      body: "Trendprijs is nu \(euro(price)) (\(e.direction.label.lowercased()) \(euro(target)))"))
                sent += 1
            } else if !met && e.alerted {
                entries[i].alerted = false
                save()
            }
        }
        return sent
    }

    /// Verwerkt de goedkoopste aanbieding (staat of beter) voor een alert per staat.
    func applyConditionResult(id: Int, cheapest: Double?) async {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].lastCheapest = cheapest
        entries[i].lastChecked = Date()
        save()
        guard let target = entries[i].target, let cond = entries[i].minCondition, let cheapest else { return }
        let met = cheapest <= target
        if met && !entries[i].alerted {
            entries[i].alerted = true
            save()
            await notifier(Notice(key: "cond-\(id)", thread: "card-\(id)", title: entries[i].name.cleanCardName,
                                  body: "\(cond.rawValue)+ vanaf \(euro(cheapest)) (je alert: onder \(euro(target)))"))
        } else if !met && entries[i].alerted {
            entries[i].alerted = false
            save()
        }
    }

    /// Registreert een koopje en geeft de melding terug die verstuurd moet worden, of nil als dat niet nodig is.
    /// Dezelfde aanbieding meldt maar één keer. Voor dezelfde kaart melden we hooguit eens per 24 uur,
    /// tenzij de nieuwe aanbieding minstens 10% goedkoper is dan de laatst gemelde.
    func registerDeal(id: Int, signature: String, price: Double, body: String, now: Date = Date()) -> Notice? {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].lastDealSignature != signature else { return nil }
        let previousPrice = entries[i].lastDealPrice, previousDate = entries[i].lastDealDate
        entries[i].lastDealSignature = signature
        var notify = true
        if let previousPrice, let previousDate, now.timeIntervalSince(previousDate) < 24 * 3600, price > previousPrice * 0.9 { notify = false }
        if notify {
            entries[i].lastDealPrice = price
            entries[i].lastDealDate = now
        }
        save()
        return notify ? Notice(key: "deal-\(id)", thread: "card-\(id)", title: "Koopje: \(entries[i].name.cleanCardName)", body: body) : nil
    }

    /// Verstuurt koopjes: tot 2 afzonderlijk, daarboven één samenvatting zodat je niet wordt overspoeld.
    func sendDeals(_ notices: [Notice]) async {
        guard !notices.isEmpty else { return }
        if notices.count <= 2 {
            for n in notices { await notifier(n) }
        } else {
            let names = notices.prefix(3).map { $0.title.replacingOccurrences(of: "Koopje: ", with: "") }.joined(separator: ", ")
            await notifier(Notice(key: "deals-summary", thread: "deals", title: "\(notices.count) koopjes gevonden",
                                  body: names + (notices.count > 3 ? " en \(notices.count - 3) meer. Open Cards om ze te bekijken." : ". Open Cards om ze te bekijken.")))
        }
    }

    /// Meldt een koopje meteen (voor één kaart).
    func applyDeal(id: Int, signature: String, price: Double = .infinity, body: String, now: Date = Date()) async {
        if let n = registerDeal(id: id, signature: signature, price: price, body: body, now: now) { await notifier(n) }
    }

    // MARK: - Notificaties

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func notify(title: String, body: String) async {
        await notify(Notice(key: UUID().uuidString, thread: "algemeen", title: title, body: body))
    }

    /// Een melding met een vaste sleutel vervangt de vorige melding met dezelfde sleutel (geen stapel dubbelen).
    static func notify(_ notice: Notice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.thread
        let req = UNNotificationRequest(identifier: notice.key, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Opslag

    private var fileURL: URL {
        let dir = storage ?? URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "watchlist.json")
    }

    func reload() { load() }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
        CloudSync.shared.localChanged("watchlist.json")
    }
}
