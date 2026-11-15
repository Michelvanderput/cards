import SwiftUI

/// Inloggen bij Cardmarket in een gewone webweergave.
struct LoginSheet: View {
    @Environment(CardmarketSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: session.isLoggedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(session.isLoggedIn ? .green : .secondary)
                    Text(session.needsCheck ? "Vink eerst de beveiligingscontrole aan."
                         : session.isLoggedIn ? "Ingelogd\(session.username.map { " als \($0)" } ?? ""). Je kunt dit venster sluiten."
                         : "Log hieronder in op Cardmarket. De app ziet je wachtwoord niet.")
                        .font(.footnote)
                    Spacer()
                }
                .padding(.horizontal)
                WebViewHost(webView: session.webView)
            }
            .navigationTitle("Cardmarket-account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
            .task {
                session.openHome()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    await session.refreshStatus()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
    }
}

/// Je eigen Cardmarket-aanbod beoordelen tegen de markt.
struct MyStockView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @Environment(CollectionStore.self) private var collection
    @Environment(ConditionChecker.self) private var checker
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .defaultValue
    @State private var reader = StockReader()
    @State private var showCheck = false
    @State private var imported: Int?

    private func entry(_ r: StockRow) -> CollectionEntry? {
        guard let pid = r.productID, let cond = r.condition, catalog.byID[pid] != nil else { return nil }
        return CollectionEntry(productID: pid, name: catalog.byID[pid]?.name ?? r.name, condition: cond,
                               quantity: r.quantity, forSale: true, askingPrice: r.price)
    }

    var body: some View {
        VStack(spacing: 0) {
            if reader.status == .needsCheck || reader.status == .needsLogin {
                Text(reader.status == .needsLogin ? "Je bent niet ingelogd. Log hieronder in op Cardmarket."
                     : "Vink de beveiligingscontrole hieronder zelf aan.")
                    .font(.footnote).foregroundStyle(.orange).padding(8)
            }
            ZStack {
                WebViewHost(webView: reader.webView)
                    .opacity(reader.status == .needsCheck || reader.status == .needsLogin ? 1 : 0)
                    .allowsHitTesting(reader.status == .needsCheck || reader.status == .needsLogin)
                if reader.status != .needsCheck && reader.status != .needsLogin { content.background(.background) }
            }
        }
        .navigationTitle("Mijn aanbod")
        .onAppear { reader.load() }
        .onDisappear { reader.stop() }
        .sheet(isPresented: $showCheck) {
            CheckSheet(title: "Marktcheck mijn aanbod") {
                var seen = Set<String>()
                let jobs = reader.rows.compactMap { r -> (productID: Int, name: String, condition: Condition?)? in
                    guard let e = entry(r), seen.insert("\(e.productID)-\(e.condition.rawValue)").inserted else { return nil }
                    return (e.productID, e.name, e.condition)
                }.prefix(25)
                await checker.refreshMarket(jobs: Array(jobs), language: languageFilter, market: market, interactive: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.status {
        case .idle, .loading:
            ProgressView("Je aanbod laden…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("Laden mislukt", systemImage: "exclamationmark.triangle",
                                   description: Text("Cardmarket gaf je aanbod niet terug. Probeer het later opnieuw."))
        default:
            let recognized = reader.rows.filter { entry($0) != nil }
            List {
                Section {
                    Text("\(reader.rows.count) regels gelezen, \(recognized.count) herkend in de catalogus.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if reader.rows.isEmpty {
                        Text("Geen regels gevonden. Pagina: \(reader.pageTitle). Dit onderdeel is experimenteel en kan afwijken per account.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if !recognized.isEmpty {
                        Button("Marktcheck (max. 25 kaarten)") { showCheck = true }
                        Button("Importeer \(recognized.count) herkende kaarten in je collectie als te koop") {
                            var added = 0
                            for r in recognized {
                                guard let e = entry(r), !collection.entries.contains(where: { $0.productID == e.productID && $0.condition == e.condition && $0.forSale }) else { continue }
                                collection.add(e); added += 1
                            }
                            imported = added
                        }
                        if let imported { Text("\(imported) kaarten toegevoegd.").font(.footnote).foregroundStyle(.green) }
                    }
                }
                Section("Beoordeling") {
                    ForEach(reader.rows) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let c = r.condition { ConditionBadge(condition: c) }
                                    Text("\(r.quantity)×").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(euro(r.price)).monospacedDigit()
                                if let e = entry(r) {
                                    let rev = SaleAdvisor.review(e, market: market, settings: settings)
                                    Text(rev.verdict.label).font(.caption2.weight(.bold)).foregroundStyle(rev.verdict.color)
                                    if let s = rev.suggested, rev.verdict == .tooHigh || rev.verdict == .belowMarket {
                                        Text("advies \(euro(s))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("niet herkend").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
