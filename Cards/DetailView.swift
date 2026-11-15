import SwiftUI
import Charts

struct DetailView: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch
    @Environment(HistoryStore.self) private var history
    @Environment(MarketStore.self) private var market
    @State private var showAlert = false

    private var current: CardItem { catalog.byID[item.id] ?? item }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    CardImage(item: current, quality: .high)
                        .frame(maxHeight: 360)
                        .shadow(radius: 6, y: 3)
                    if let set = catalog.setName(for: current) {
                        Text(set).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section("Prijsverloop (trend)") {
                let pts = history.points[item.id] ?? []
                if pts.count >= 2 {
                    Chart(pts) { LineMark(x: .value("Datum", $0.date), y: .value("EUR", $0.price)) }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .frame(height: 140)
                } else {
                    Text("De geschiedenis wordt vanaf nu elke dag bijgehouden voor kaarten die je bekijkt of volgt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Cardmarket (trend, alle staten)", value: euro(current.mainPrice))
                if let tcg = market.tcgplayerEUR(item.id) {
                    LabeledContent("TCGplayer (marktprijs, VS)", value: euro(tcg))
                    if let cm = current.mainPrice, tcg > 0 {
                        let diff = (cm - tcg) / tcg
                        LabeledContent("Cardmarket t.o.v. TCGplayer", value: diff.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
                    }
                } else if catalog.map.exact.contains(item.id) {
                    Text("Geen TCGplayer-prijs gevonden voor deze variant.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Voor deze kaart is geen betrouwbare koppeling met andere platforms.").font(.footnote).foregroundStyle(.secondary)
                }
                if let s = market.stats(item.id, minCondition: nil) ?? market.stats(item.id, minCondition: .nm) {
                    LabeledContent("Aanbiedingen: goedkoopste", value: euro(s.min))
                    LabeledContent("Aanbiedingen: mediaan (\(s.count))", value: euro(s.median))
                }
            } header: {
                Text("Prijsvergelijking")
            } footer: {
                Text("TCGplayer-prijzen zijn de Amerikaanse markt (USD, omgerekend met de ECB-koers) en alleen indicatief: verzend- en invoerkosten en de staat verschillen.")
            }
            Section("Cardmarket-gemiddelde, alle staten (EUR)") { rows(current.normal) }
            if !current.holo.isEmpty {
                Section("Holo / foil") { rows(current.holo) }
            }
            Section {
                if let e = watch.entry(item.id) {
                    if let summary = e.alertSummary {
                        LabeledContent("Alert", value: summary)
                    }
                    Button("Alert instellen…") { showAlert = true }
                    Button("Van watchlist halen", role: .destructive) { watch.remove(item.id) }
                } else {
                    Button("Aan watchlist toevoegen") { watch.add(item) }
                }
                NavigationLink("Aanbiedingen per staat") { ListingsView(item: current) }
                Link("Open op Cardmarket", destination: current.cardmarketURL)
            }
        }
        .navigationTitle(item.name)
        .onAppear { history.record(id: item.id, price: current.mainPrice) }
        .task { await market.fetchCrossMarket(item: item, map: catalog.map) }
        .sheet(isPresented: $showAlert) { AlertSheet(item: current) }
    }

    @ViewBuilder
    private func rows(_ p: PriceSet) -> some View {
        LabeledContent("Trend", value: euro(p.trend))
        LabeledContent("Gemiddelde", value: euro(p.avg))
        LabeledContent("Laagste", value: euro(p.low))
        LabeledContent("Gem. 1 dag", value: euro(p.avg1))
        LabeledContent("Gem. 7 dagen", value: euro(p.avg7))
        LabeledContent("Gem. 30 dagen", value: euro(p.avg30))
    }
}

struct AlertSheet: View {
    let item: CardItem
    @Environment(WatchStore.self) private var watch
    @Environment(MarketStore.self) private var market
    @Environment(\.dismiss) private var dismiss
    @State private var direction: AlertDirection = .below
    @State private var condition: Condition? = nil
    @State private var target: Double?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Staat", selection: $condition) {
                    Text("Alle (trendprijs)").tag(Condition?.none)
                    ForEach(Condition.filterChoices) { Text($0.rawValue + " of beter").tag(Condition?.some($0)) }
                }
                if condition == nil {
                    Picker("Melden wanneer prijs", selection: $direction) {
                        ForEach(AlertDirection.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                TextField("Prijs in EUR", value: $target, format: .number)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if let sug = DealAnalyzer.suggestion(item: item, minCondition: condition, market: market), condition != nil || direction == .below {
                    Section("Voorstel") {
                        Button("Gebruik \(euro(sug.price))") { target = sug.price }
                        Text(sug.basis).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Nu (trend, alle staten): \(euro(item.mainPrice))").foregroundStyle(.secondary)
                    if condition != nil {
                        Text("Alerts per staat kijken naar de goedkoopste aanbieding op Cardmarket. Dat gebeurt zolang de app open staat, of als je Watchlist controleren kiest.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Prijsalert")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaar") {
                        watch.setAlert(item.id, target: target, direction: direction, minCondition: condition)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let e = watch.entry(item.id) { direction = e.direction; target = e.target; condition = e.minCondition }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}
