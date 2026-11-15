import SwiftUI
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// Zorgt dat meldingen ook als banner verschijnen terwijl de app open staat.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct CardsApp: App {
    @State private var catalog = CatalogStore()
    @State private var watch = WatchStore()
    @State private var history = HistoryStore()
    @State private var checker = ConditionChecker()
    @State private var market = MarketStore()
    @State private var collection = CollectionStore()
    @State private var binders = BinderStore()
    @State private var appSettings = AppSettings()
    @State private var session = CardmarketSession()
    @AppStorage("autoCheck") private var autoCheck = true
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .defaultValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Ruime cache: kaartafbeeldingen hoeven zo niet steeds opnieuw geladen te worden.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 400 << 20)
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        Task.detached(priority: .utility) { await ImageStore.shared.prune() }
        #if DEBUG
        if CommandLine.arguments.contains("--selftest-notifications") { Self.selfTestNotifications() }
        #endif
    }

    #if DEBUG
    /// Alleen voor ontwikkeling: meldt of meldingen zijn toegestaan en of een melding echt aankomt. Vraagt zelf geen toestemming.
    private static func selfTestNotifications() {
        Task { @MainActor in
            let status = await WatchStore.authorizationStatus()
            NSLog("SELFTEST status=%@ allowed=%d", NotificationSupport.describe(status), NotificationSupport.isAllowed(status) ? 1 : 0)
            if NotificationSupport.isAllowed(status) {
                let center = UNUserNotificationCenter.current()
                let existing = await center.deliveredNotifications()
                let titles = Dictionary(grouping: existing, by: { $0.request.content.title }).mapValues(\.count)
                NSLog("SELFTEST bestaande meldingen per titel: %@", String(describing: titles))
                let before = existing.count
                // Twee meldingen met dezelfde sleutel moeten als één in het meldingencentrum staan (de tweede vervangt de eerste).
                await WatchStore.notify(Notice(key: "selftest-replace", thread: "selftest", title: "Selftest", body: "eerste \(Date())"))
                try? await Task.sleep(for: .seconds(1.5))
                await WatchStore.notify(Notice(key: "selftest-replace", thread: "selftest", title: "Selftest", body: "tweede \(Date())"))
                try? await Task.sleep(for: .seconds(1.5))
                let delivered = await center.deliveredNotifications()
                let same = delivered.filter { $0.request.identifier == "selftest-replace" }
                NSLog("SELFTEST delivered before=%d after=%d metZelfdeSleutel=%d tekst=%@", before, delivered.count, same.count, same.first?.request.content.body ?? "-")
                center.removeDeliveredNotifications(withIdentifiers: ["selftest-replace"])
            }
            exit(0)
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(catalog)
                .environment(watch)
                .environment(history)
                .environment(checker)
                .environment(market)
                .environment(collection)
                .environment(binders)
                .environment(appSettings)
                .environment(session)
                .onChange(of: collection.entries) { _, _ in
                    WidgetBridge.update(collection: collection, catalog: catalog, settings: appSettings)
                }
                .task {
                    CloudSync.shared.onRemoteChange = { file in
                        switch file {
                        case "collection.json": collection.reload()
                        case "watchlist.json": watch.reload()
                        case "binders.json": binders.reload()
                        case "history.json": history.reload()
                        case "ratelimit.json": RateLimitState.shared.reloadFromFile()
                        default: break
                        }
                    }
                    await CloudSync.shared.start()
                    await refreshAll()
                    #if DEBUG
                    if let i = CommandLine.arguments.firstIndex(of: "--selftest-search"), i + 1 < CommandLine.arguments.count {
                        await selfTestSearch(count: Int(CommandLine.arguments[i + 1]) ?? 10)
                    }
                    #endif
                    #if os(macOS)
                    // Op de Mac blijft de app vaak open: elke 30 minuten alerts opnieuw controleren.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1800))
                        await refreshAll()
                    }
                    #endif
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Prijzen verversen") { Task { await catalog.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        #endif
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Self.scheduleBackgroundRefresh() }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            await refreshPrices()
            Self.scheduleBackgroundRefresh()
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(catalog).environment(watch).environment(history).environment(checker)
                .environment(market).environment(collection).environment(binders)
                .environment(appSettings).environment(session)
                .frame(width: 540, height: 640)
        }
        #endif
    }

    /// Prijsbestanden + trend-alerts (kan ook op de achtergrond).
    @MainActor
    private func refreshPrices() async {
        // Zijn er alerts en is nog niet naar meldingen gevraagd, vraag het dan nu (anders merk je nooit iets van een alert).
        if watch.entries.contains(where: { $0.target != nil || $0.dealAlert == true }),
           await WatchStore.authorizationStatus() == .notDetermined {
            _ = await WatchStore.requestPermission()
        }
        await catalog.start()
        for e in watch.entries { history.record(id: e.id, price: catalog.byID[e.id]?.mainPrice) }
        history.record(id: HistoryStore.portfolioID, price: collection.entries.isEmpty ? nil : collection.totalValue(catalog: catalog))
        await watch.evaluate(catalog: catalog)
        WidgetBridge.update(collection: collection, catalog: catalog, settings: appSettings)
    }

    /// Alles, inclusief alerts per staat (vraagt de webweergave, dus alleen met de app open).
    @MainActor
    private func refreshAll() async {
        await refreshPrices()
        if autoCheck {
            await checker.run(watch: watch, language: languageFilter, market: market, settings: appSettings, catalog: catalog,
                                interactive: false, minimumAge: 3 * 3600, maxEntries: 12)
        }
    }

    #if DEBUG
    /// Alleen voor ontwikkeling: draait de zoektocht naar beste deals over de eerste N ontbrekende kaarten en logt de voortgang.
    @MainActor
    private func selfTestSearch(count: Int) async {
        NSLog("SEARCH start: catalogus %d items", catalog.items.count)
        let cards = catalog.goalCards(.exEra)
        let jobs = Array(cards.prefix(count)).map { (productID: $0.id, name: $0.name, condition: Optional(Condition.ex)) }
        NSLog("SEARCH doel heeft %d kaarten, zoek %d", cards.count, jobs.count)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                NSLog("SEARCH ..voortgang done=%d/%d huidig=%@ status=%@ loading=%d", checker.done, checker.total,
                      checker.current?.cleanCardName ?? "-", "\(checker.loader.status)", checker.loader.webView.isLoading ? 1 : 0)
            }
        }
        let t0 = Date()
        let fetched = await checker.refreshMarket(jobs: jobs, language: .english, market: market, interactive: true)
        monitor.cancel()
        NSLog("SEARCH klaar: %d opgehaald in %.0fs, needsAttention=%d", fetched, Date().timeIntervalSince(t0), checker.needsAttention ? 1 : 0)
        exit(0)
    }
    #endif

    nonisolated static let refreshID = "nl.michelvanderput.cards.refresh"

    #if os(iOS)
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
