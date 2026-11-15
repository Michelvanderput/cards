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
    @AppStorage("autoCheck") private var autoCheck = true
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Ruime cache: kaartafbeeldingen hoeven zo niet steeds opnieuw geladen te worden.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 400 << 20)
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

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
                .task {
                    await refreshAll()
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
                .environment(catalog)
                .frame(width: 480, height: 460)
        }
        #endif
    }

    /// Prijsbestanden + trend-alerts (kan ook op de achtergrond).
    @MainActor
    private func refreshPrices() async {
        await catalog.start()
        for e in watch.entries { history.record(id: e.id, price: catalog.byID[e.id]?.mainPrice) }
        await watch.evaluate(catalog: catalog)
    }

    /// Alles, inclusief alerts per staat (vraagt de webweergave, dus alleen met de app open).
    @MainActor
    private func refreshAll() async {
        await refreshPrices()
        if autoCheck {
            await checker.run(watch: watch, language: languageFilter, market: market, interactive: false, minimumAge: 15 * 60)
        }
    }

    nonisolated static let refreshID = "nl.michelvanderput.cards.refresh"

    #if os(iOS)
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
