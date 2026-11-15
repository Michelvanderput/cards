import Foundation
import Observation

/// Controleert alle alerts per staat door de aanbiedingen van de gevolgde kaarten één voor één te laden.
/// Werkt alleen zolang de app draait. Vraagt Cardmarket een beveiligingscontrole, dan stopt de achtergrondrun
/// en meldt de app dat jij die even moet doen.
@MainActor
@Observable
final class ConditionChecker {
    /// De controle laadt zonder plaatjes en trackers: veel minder verkeer naar Cardmarket per pagina.
    let loader = ListingsLoader(blockHeavyResources: true)
    /// Wanneer een kaart voor het laatst is opgehaald (met staat en taal), zodat we hem niet meteen opnieuw laden.
    private var fetchedAt: [Int: (date: Date, key: String)] = [:]
    private(set) var isRunning = false
    private(set) var current: String?
    private(set) var done = 0
    private(set) var total = 0
    private(set) var needsAttention = false
    private(set) var startedAt: Date?
    /// Laatst geladen aanbiedingen per kaart (voor de bundelweergave en beste deals).
    private(set) var lastListings: [Int: [Listing]] = [:]
    private var lastAttentionNotice: Date?
    private var cancelRequested = false
    /// Na zoveel opgehaalde kaarten volgt een rustpauze (seconden), zodat een grote scan niet aanhoudend veel verkeer geeft.
    var breakEvery = 20
    var breakSeconds: TimeInterval = 45
    private(set) var isResting = false

    var needsCheckNow: Bool { loader.status == .needsCheck }

    /// Geschatte resterende tijd op basis van de snelheid tot nu toe.
    var remainingEstimate: TimeInterval? {
        guard isRunning, done > 0, let startedAt else { return nil }
        let perItem = Date().timeIntervalSince(startedAt) / Double(done)
        return perItem * Double(max(total - done, 0))
    }

    // MARK: - Annuleren

    /// Stopt de lopende controle (Stop-knop, sluiten van het scherm of een nieuwe handmatige taak).
    func cancel() {
        cancelRequested = true
        loader.stop()
    }

    /// Een handmatige taak neemt het over van een lopende (bijvoorbeeld de automatische controle op de achtergrond).
    private func preemptRunningJob() async {
        guard isRunning else { return }
        cancel()
        for _ in 0..<50 where isRunning {
            guard await pause(.milliseconds(100), honoringCancel: false) else { return }
        }
    }

    /// Pauze die bij annuleren meteen stopt (geen `try?`: een genegeerde annulering laat een lus doordraaien
    /// zonder te wachten en blokkeert dan de hele app). Geeft false terug als er geannuleerd is.
    private func pause(_ duration: Duration, honoringCancel: Bool = true) async -> Bool {
        do { try await Task.sleep(for: duration) } catch { return false }
        return !(honoringCancel && (Task.isCancelled || cancelRequested))
    }

    private enum Wait { case finished, cancelled, needsAttention, rateLimited }

    /// Wacht tot de aanbieding is geladen. Stopt meteen bij annuleren.
    private func waitForLoader(interactive: Bool) async -> Wait {
        while loader.isPolling {
            if Task.isCancelled || cancelRequested { loader.stop(); return .cancelled }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { loader.stop(); return .cancelled }
            if !interactive && loader.status == .needsCheck { loader.stop(); return .needsAttention }
        }
        if loader.status == .rateLimited { return .rateLimited }
        return (Task.isCancelled || cancelRequested) ? .cancelled : .finished
    }

    private func begin(total: Int) {
        isRunning = true
        cancelRequested = false
        needsAttention = false
        self.total = total
        done = 0
        startedAt = Date()
    }

    private func end() {
        isRunning = false
        isResting = false
        current = nil
        startedAt = nil
    }

    // MARK: - Alerts per staat en koopjes (watchlist)

    /// Welke kaarten er aan de beurt zijn: alleen wat lang genoeg geleden is gecontroleerd, de langst niet-gecontroleerde eerst,
    /// en hooguit `maxEntries` (zodat een lange watchlist niet in één keer de hele app en Cardmarket bezighoudt).
    static func selectDue(_ entries: [WatchEntry], minimumAge: TimeInterval, maxEntries: Int?, now: Date = Date()) -> [WatchEntry] {
        var due = entries.filter { minimumAge == 0 || $0.lastChecked.map { now.timeIntervalSince($0) > minimumAge } ?? true }
        if let maxEntries {
            due = Array(due.sorted { ($0.lastChecked ?? .distantPast) < ($1.lastChecked ?? .distantPast) }.prefix(maxEntries))
        }
        return due
    }

    /// - Parameters:
    ///   - interactive: true = de gebruiker kijkt mee en kan een beveiligingscontrole aantikken; neemt een lopende taak over.
    ///   - maxEntries: begrenst het aantal kaarten per ronde (de langst niet gecontroleerde eerst); voor automatische rondes.
    func run(watch: WatchStore, language: LanguageFilter, market: MarketStore? = nil, settings: AppSettings, catalog: CatalogStore,
             interactive: Bool, minimumAge: TimeInterval = 0, maxEntries: Int? = nil) async {
        if isRunning {
            guard interactive else { return }
            await preemptRunningJob()
            if isRunning { return }
        }
        guard !RateLimitState.shared.isCoolingDown else { return }   // Cardmarket beperkt ons: even niets sturen
        let due = Self.selectDue(watch.conditionEntries, minimumAge: minimumAge, maxEntries: maxEntries)
        guard !due.isEmpty else { return }
        begin(total: due.count)
        defer { end() }

        var deals: [Notice] = []
        loop: for entry in due {
            if Task.isCancelled || cancelRequested { break }
            let cond = entry.minCondition
            current = entry.name
            loader.load(productID: entry.id, minCondition: cond, language: language, loadMore: 1)
            switch await waitForLoader(interactive: interactive) {
            case .cancelled: break loop
            case .needsAttention:
                needsAttention = true
                await watch.sendDeals(deals)
                await noticeAttention()
                return
            case .rateLimited:
                await watch.sendDeals(deals)
                return
            case .finished: break
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
                        let advice = sc.advice == .askPhoto ? " Vraag eerst een foto." : sc.advice == .checkPhoto ? " Check eerst de foto."
                            : sc.advice == .suspicious ? " Opvallend goedkoop: controleer goed." : ""
                        if let notice = watch.registerDeal(id: entry.id, signature: "\(best.seller)|\(best.price)|\(best.condition)", price: sc.total,
                                                           body: "\(best.condition) voor \(euro(best.price)) uit \(best.country), dealscore \(sc.value)\(off).\(advice)") {
                            deals.append(notice)
                        }
                    }
                }
            }
            done += 1
            guard await pause(.seconds(2)) else { break }   // rustig aan: één kaart tegelijk, met pauze
        }
        await watch.sendDeals(deals)
    }

    // MARK: - Marktcheck voor willekeurige kaarten (verkoopaanbod, beste deals van een doel)

    /// Haalt de aanbiedingen op voor een lijst kaarten en bewaart de marktstatistieken en aanbiedingen.
    /// Geeft het aantal kaarten terug dat daadwerkelijk is opgehaald.
    @discardableResult
    func refreshMarket(jobs: [(productID: Int, name: String, condition: Condition?)], language: LanguageFilter,
                       market: MarketStore, interactive: Bool, maxAge: TimeInterval = 30 * 60) async -> Int {
        guard !jobs.isEmpty, !RateLimitState.shared.isCoolingDown else { return 0 }
        if isRunning {
            guard interactive else { return 0 }
            await preemptRunningJob()
            if isRunning { return 0 }
        }
        begin(total: jobs.count)
        defer { end() }
        var fetched = 0
        loop: for job in jobs {
            if Task.isCancelled || cancelRequested { break }
            current = job.name
            // Net opgehaald (zelfde staat en taal)? Dan hoeven we Cardmarket niet opnieuw te vragen.
            let key = "\(job.condition?.rawValue ?? "-")|\(language.rawValue)"
            if let known = fetchedAt[job.productID], known.key == key, Date().timeIntervalSince(known.date) < maxAge,
               lastListings[job.productID] != nil {
                done += 1
                fetched += 1
                continue
            }
            #if DEBUG
            let t0 = Date()
            #endif
            loader.load(productID: job.productID, minCondition: job.condition, language: language, loadMore: 1)
            switch await waitForLoader(interactive: interactive) {
            case .cancelled: break loop
            case .needsAttention: needsAttention = true; return fetched
            case .rateLimited: return fetched
            case .finished: break
            }
            #if DEBUG
            NSLog("SEARCH kaart %d/%d %@ status=%@ listings=%d %.1fs | pagina: %@", done + 1, total, job.name.cleanCardName, "\(loader.status)", loader.listings.count, Date().timeIntervalSince(t0), loader.status == .done ? "-" : loader.lastDiagnostic)
            #endif
            if loader.status == .done {
                lastListings[job.productID] = loader.listings
                fetchedAt[job.productID] = (Date(), key)
                market.recordListings(id: job.productID, minCondition: job.condition, listings: loader.listings)
                fetched += 1
            }
            done += 1
            guard await pause(.seconds(0.5)) else { break }   // de vaste pauze tussen ladingen regelt RequestGate
            if breakEvery > 0, fetched > 0, fetched % breakEvery == 0, done < jobs.count {
                isResting = true
                let ok = await pause(.seconds(breakSeconds))
                isResting = false
                if !ok { break }
            }
        }
        return fetched
    }

    private func noticeAttention() async {
        if let last = lastAttentionNotice, Date().timeIntervalSince(last) < 12 * 3600 { return }
        lastAttentionNotice = Date()
        await WatchStore.notify(Notice(key: "attention", thread: "algemeen", title: "Controle nodig",
                                       body: "Cardmarket vraagt een beveiligingscontrole. Open Cards en tik 'Watchlist controleren'."))
    }
}
