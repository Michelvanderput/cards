import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct CardsApp: App {
    @State private var catalog = CatalogStore()
    @State private var watch = WatchStore()
    @State private var history = HistoryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(catalog)
                .environment(watch)
                .environment(history)
                .task { await refreshAll() }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Self.scheduleBackgroundRefresh() }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            await refreshAll()
            Self.scheduleBackgroundRefresh()
        }
        #endif
    }

    @MainActor
    private func refreshAll() async {
        await catalog.start()
        for e in watch.entries { history.record(id: e.id, price: catalog.byID[e.id]?.mainPrice) }
        await watch.evaluate(catalog: catalog)
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
