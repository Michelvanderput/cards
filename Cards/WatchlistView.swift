import SwiftUI

struct WatchlistView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch
    @Environment(ConditionChecker.self) private var checker
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all
    @State private var showCheck = false
    @State private var showBundle = false

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
                if !checker.lastListings.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showBundle = true } label: { Label("Bundelen", systemImage: "shippingbox.and.arrow.backward") }
                    }
                }
                if !watch.conditionEntries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showCheck = true } label: { Label("Controleren", systemImage: "checkmark.arrow.trianglehead.counterclockwise") }
                    }
                }
            }
            .sheet(isPresented: $showBundle) { BundleView() }
            .sheet(isPresented: $showCheck) {
                CheckSheet(title: "Watchlist controleren") {
                    await checker.run(watch: watch, language: languageFilter, market: market, settings: settings, catalog: catalog, interactive: true)
                }
            }
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
    let title: String
    let start: () async -> Void
    @Environment(ConditionChecker.self) private var checker
    @Environment(\.dismiss) private var dismiss

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
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Sluit") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { Task { await start() } }
                        .disabled(checker.isRunning)
                }
            }
            .task { await start() }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}

/// Verkopers die meerdere kaarten van je watchlist hebben: bundelen bespaart verzendkosten.
struct BundleView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch
    @Environment(ConditionChecker.self) private var checker
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private struct SellerBundle: Identifiable {
        let id: String
        let country: String
        let cards: [(name: String, price: Double)]
        var count: Int { cards.count }
        var sum: Double { cards.reduce(0) { $0 + $1.price } }
    }

    private var bundles: [SellerBundle] {
        var bySeller: [String: (country: String, cards: [(String, Double)])] = [:]
        for entry in watch.entries {
            guard let listings = checker.lastListings[entry.id] else { continue }
            let relevant = entry.minCondition.map { c in listings.filter { Condition.order($0.condition) <= c.level } } ?? listings
            // Per verkoper alleen de goedkoopste aanbieding van deze kaart.
            for (seller, items) in Dictionary(grouping: relevant, by: \.seller) {
                guard let best = items.min(by: { $0.price < $1.price }) else { continue }
                bySeller[seller, default: (best.country, [])].cards.append((entry.name, best.price))
            }
        }
        return bySeller.map { SellerBundle(id: $0.key, country: $0.value.country, cards: $0.value.cards.map { (name: $0.0, price: $0.1) }) }
            .filter { $0.count >= 2 }
            .sorted { ($0.count, -$0.sum) > ($1.count, -$1.sum) }
    }

    var body: some View {
        NavigationStack {
            let list = bundles
            List {
                ForEach(list) { b in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(AppSettings.flag(b.country)) \(b.id)").font(.headline)
                            Spacer()
                            Text("\(b.count) kaarten").font(.subheadline.weight(.semibold))
                        }
                        ForEach(b.cards.indices, id: \.self) { i in
                            HStack { Text(b.cards[i].name).lineLimit(1); Spacer(); Text(euro(b.cards[i].price)).monospacedDigit() }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let separate = b.cards.reduce(0) { $0 + settings.shipping(from: b.country, price: $1.price) }
                        let combined = settings.shipping(from: b.country, price: b.sum)
                        HStack {
                            Text("Totaal \(euro(b.sum))").fontWeight(.medium)
                            Spacer()
                            if separate > combined {
                                Text("verzending bespaard ≈ \(euro(separate - combined))").foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if list.isEmpty {
                    ContentUnavailableView("Geen bundels gevonden", systemImage: "shippingbox",
                        description: Text("Geen enkele verkoper heeft op dit moment meer dan één kaart van je watchlist. Voer eerst Watchlist controleren uit."))
                }
            }
            .navigationTitle("Slim bundelen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}
