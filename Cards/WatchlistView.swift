import SwiftUI

struct WatchlistView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch
    @Environment(ConditionChecker.self) private var checker
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all
    @State private var showCheck = false

    var body: some View {
        NavigationStack {
            List {
                if checker.needsAttention {
                    Label("Cardmarket vraagt een beveiligingscontrole. Tik op Controleren en vink die aan.", systemImage: "exclamationmark.shield")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(watch.entries) { e in
                    if let item = catalog.byID[e.id] {
                        NavigationLink(value: item) { row(item: item, entry: e) }
                    } else {
                        Text(e.name)
                    }
                }
                .onDelete { idx in idx.map { watch.entries[$0].id }.forEach(watch.remove) }
            }
            .overlay {
                if watch.entries.isEmpty {
                    ContentUnavailableView("Watchlist is leeg", systemImage: "bell",
                                           description: Text("Voeg kaarten toe vanuit de zoekresultaten."))
                }
            }
            .navigationTitle("Watchlist")
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .toolbar {
                if !watch.conditionEntries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showCheck = true } label: { Label("Controleren", systemImage: "checkmark.arrow.trianglehead.counterclockwise") }
                    }
                }
            }
            .sheet(isPresented: $showCheck) { CheckSheet() }
        }
    }

    private func row(item: CardItem, entry e: WatchEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CardRow(item: item)
            if let summary = e.alertSummary {
                HStack {
                    Label(summary, systemImage: e.alerted ? "bell.badge.fill" : "bell")
                    if let c = e.lastCheapest, let cond = e.minCondition {
                        Text("· nu \(cond.rawValue)+ \(euro(c))")
                    }
                }
                .font(.caption).foregroundStyle(e.alerted ? .green : .secondary)
            }
        }
    }
}

/// Toont de voortgang van de controle en, als Cardmarket dat vraagt, de beveiligingscontrole.
struct CheckSheet: View {
    @Environment(WatchStore.self) private var watch
    @Environment(ConditionChecker.self) private var checker
    @Environment(\.dismiss) private var dismiss
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if checker.isRunning {
                    ProgressView(value: Double(checker.done), total: Double(max(checker.total, 1)))
                    Text("Controleer \(checker.current ?? "…") (\(checker.done + 1) van \(checker.total))")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(checker.total == 0 ? "Klaar om te starten." : "Klaar. Alerts zijn bijgewerkt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if checker.needsCheckNow {
                    Text("Cardmarket vraagt een beveiligingscontrole. Vink 'Verify you are human' hieronder zelf aan.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                WebViewHost(webView: checker.loader.webView)
                    .opacity(checker.needsCheckNow ? 1 : 0)
                    .allowsHitTesting(checker.needsCheckNow)
                if !checker.needsCheckNow { Spacer() }
            }
            .padding()
            .navigationTitle("Watchlist controleren")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Sluit") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await checker.run(watch: watch, language: languageFilter, interactive: true) } }
                        .disabled(checker.isRunning)
                }
            }
            .task { await checker.run(watch: watch, language: languageFilter, interactive: true) }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}
