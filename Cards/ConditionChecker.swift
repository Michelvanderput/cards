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
    /// Laatst geladen aanbiedingen per kaart (voor de bundelweergave).
    private(set) var lastListings: [Int: [Listing]] = [:]
    private var lastAttentionNotice: Date?

    var needsCheckNow: Bool { loader.status == .needsCheck }

    /// - Parameter interactive: true = de gebruiker kijkt mee en kan een beveiligingscontrole aantikken.
    func run(watch: WatchStore, language: LanguageFilter, market: MarketStore? = nil, settings: AppSettings, catalog: CatalogStore,
             interactive: Bool, minimumAge: TimeInterval = 0) async {
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
            let cond = entry.minCondition
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
                let listings = loader.listings
                lastListings[entry.id] = listings
                market?.recordListings(id: entry.id, minCondition: cond, listings: listings)
                let relevant = cond.map { c in listings.filter { Condition.order($0.condition) <= c.level } } ?? listings
                if cond != nil, entry.target != nil {
                    await watch.applyConditionResult(id: entry.id, cheapest: relevant.map(\.price).min())
                }
                if entry.dealAlert == true {
                    let scores = DealEngine.analyze(relevant, settings: settings, tcgplayerEUR: market?.tcgplayerEUR(entry.id),
                                                    trend: catalog.byID[entry.id]?.mainPrice)
                    if let best = relevant.max(by: { (scores[$0.id]?.value ?? 0) < (scores[$1.id]?.value ?? 0) }),
                       let sc = scores[best.id], sc.value >= 80 {
                        let off = sc.discount.map { " (\(Int(($0 * 100).rounded()))% onder de markt)" } ?? ""
                        await watch.applyDeal(id: entry.id, signature: "\(best.seller)|\(best.price)|\(best.condition)",
                                              body: "\(best.condition) voor \(euro(best.price)) uit \(best.country), dealscore \(sc.value)\(off)."
                                                + (sc.advice == .askPhoto ? " Vraag eerst een foto." : sc.advice == .checkPhoto ? " Check eerst de foto." : sc.advice == .suspicious ? " Opvallend goedkoop: controleer goed." : ""))
                    }
                }
            }
            done += 1
            try? await Task.sleep(for: .seconds(3))   // rustig aan: één kaart tegelijk, met pauze
        }
    }

    /// Haalt de aanbiedingen op voor een lijst kaarten (bijv. je verkoopaanbod) en bewaart de marktstatistieken.
    func refreshMarket(jobs: [(productID: Int, name: String, condition: Condition?)], language: LanguageFilter,
                       market: MarketStore, interactive: Bool) async {
        guard !isRunning, !jobs.isEmpty else { return }
        isRunning = true
        needsAttention = false
        total = jobs.count
        done = 0
        defer { isRunning = false; current = nil }
        for job in jobs {
            current = job.name
            loader.load(productID: job.productID, minCondition: job.condition, language: language)
            while loader.isPolling {
                try? await Task.sleep(for: .milliseconds(500))
                if !interactive && loader.status == .needsCheck { loader.stop(); needsAttention = true; return }
            }
            if loader.status == .done {
                lastListings[job.productID] = loader.listings
                market.recordListings(id: job.productID, minCondition: job.condition, listings: loader.listings)
            }
            done += 1
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func noticeAttention() async {
        if let last = lastAttentionNotice, Date().timeIntervalSince(last) < 12 * 3600 { return }
        lastAttentionNotice = Date()
        await WatchStore.notify(title: "Controle nodig",
                                body: "Cardmarket vraagt een beveiligingscontrole. Open Cards en tik 'Watchlist controleren'.")
    }
}
