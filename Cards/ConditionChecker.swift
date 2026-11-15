import Foundation
import Observation

/// Controleert alle alerts per staat door de aanbiedingen van de gevolgde kaarten één voor één te laden.
/// Werkt alleen zolang de app draait. Vraagt Cardmarket een beveiligingscontrole, dan stopt de achtergrondrun
/// en meldt de app dat jij die even moet doen.
@MainActor
@Observable
final class ConditionChecker {
    let loader = ListingsLoader()
    private(set) var isRunning = false
    private(set) var current: String?
    private(set) var done = 0
    private(set) var total = 0
    private(set) var needsAttention = false
    private var lastAttentionNotice: Date?

    var needsCheckNow: Bool { loader.status == .needsCheck }

    /// - Parameter interactive: true = de gebruiker kijkt mee en kan een beveiligingscontrole aantikken.
    func run(watch: WatchStore, language: LanguageFilter, interactive: Bool, minimumAge: TimeInterval = 0) async {
        guard !isRunning else { return }
        let due = watch.conditionEntries.filter {
            minimumAge == 0 || $0.lastChecked.map { Date().timeIntervalSince($0) > minimumAge } ?? true
        }
        guard !due.isEmpty else { return }
        isRunning = true
        needsAttention = false
        total = due.count
        done = 0
        defer { isRunning = false; current = nil }

        for entry in due {
            guard let cond = entry.minCondition else { continue }
            current = entry.name
            loader.load(productID: entry.id, minCondition: cond, language: language)
            while loader.isPolling {
                try? await Task.sleep(for: .milliseconds(500))
                if !interactive && loader.status == .needsCheck {
                    loader.stop()
                    needsAttention = true
                    await noticeAttention()
                    return
                }
            }
            if loader.status == .done {
                let cheapest = loader.listings
                    .filter { Condition.order($0.condition) <= cond.level }
                    .map(\.price).min()
                await watch.applyConditionResult(id: entry.id, cheapest: cheapest)
            }
            done += 1
            try? await Task.sleep(for: .seconds(3))   // rustig aan: één kaart tegelijk, met pauze
        }
    }

    private func noticeAttention() async {
        if let last = lastAttentionNotice, Date().timeIntervalSince(last) < 12 * 3600 { return }
        lastAttentionNotice = Date()
        await WatchStore.notify(title: "Controle nodig",
                                body: "Cardmarket vraagt een beveiligingscontrole. Open Cards en tik 'Watchlist controleren'.")
    }
}
