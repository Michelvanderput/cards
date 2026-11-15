import SwiftUI
import Charts

struct CollectionView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(CollectionStore.self) private var collection
    @Environment(HistoryStore.self) private var history
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @Environment(ConditionChecker.self) private var checker
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .defaultValue
    @State private var editing: CollectionEntry?
    @State private var query = ""
    @State private var onlyForSale = false
    @State private var showMarketCheck = false

    private var filtered: [CollectionEntry] {
        var list = collection.entries
        if onlyForSale { list = list.filter(\.forSale) }
        list.sort {
            (collection.unitValue($0, catalog: catalog) ?? 0) * Double($0.quantity) >
            (collection.unitValue($1, catalog: catalog) ?? 0) * Double($1.quantity)
        }
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !collection.entries.isEmpty {
                    summary.listRowInsets(.init()).listRowBackground(Color.clear)
                    movers
                }
                Section {
                    ForEach(filtered) { e in
                        if let item = catalog.byID[e.productID] {
                            Button { editing = e } label: { row(e, item) }.buttonStyle(.plain)
                                .swipeActions { Button("Verwijder", role: .destructive) { collection.remove(e.id) } }
                        }
                    }
                } header: {
                    if !collection.entries.isEmpty {
                        Picker("Filter", selection: $onlyForSale) {
                            Text("Alles").tag(false)
                            Text("Te koop (\(collection.entries.filter(\.forSale).count))").tag(true)
                        }
                        .pickerStyle(.segmented).textCase(nil)
                    }
                }
            }
            .overlay {
                if collection.entries.isEmpty {
                    ContentUnavailableView("Je collectie is leeg", systemImage: "rectangle.stack",
                        description: Text("Open een kaart en kies Collectie om hem toe te voegen, met staat en je eigen prijs."))
                }
            }
            .searchable(text: $query, prompt: "Zoek in je collectie")
            .navigationTitle("Collectie")
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if collection.entries.contains(where: \.forSale) {
                        Button { showMarketCheck = true } label: { Label("Marktcheck", systemImage: "chart.bar.doc.horizontal") }
                    }
                    if !collection.entries.isEmpty {
                        ShareLink(item: csvURL) { Label("Exporteer CSV", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .sheet(item: $editing) { entry in
                if let item = catalog.byID[entry.productID] { AddToCollectionSheet(item: item, existing: entry) }
            }
            .sheet(isPresented: $showMarketCheck) {
                CheckSheet(title: "Marktcheck verkoopaanbod") {
                    var seen = Set<String>()
                    let jobs = collection.entries.filter(\.forSale).compactMap { e -> (productID: Int, name: String, condition: Condition?)? in
                        seen.insert("\(e.productID)-\(e.condition.rawValue)").inserted ? (e.productID, e.name, e.condition) : nil
                    }
                    await checker.refreshMarket(jobs: jobs, language: languageFilter, market: market, interactive: true)
                }
            }
        }
    }

    // MARK: - Samenvatting

    private var summary: some View {
        let value = collection.totalValue(catalog: catalog)
        let paid = collection.totalPaid
        let sale = collection.entries.filter(\.forSale)
        let askValue = sale.reduce(0) { $0 + ($1.askingPrice ?? collection.unitValue($1, catalog: catalog) ?? 0) * Double($1.quantity) }
        let series = history.points[HistoryStore.portfolioID] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text("Totale waarde").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Text(settings.money(value)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            HStack(spacing: 18) {
                stat("Kaarten", "\(collection.totalCards)")
                if paid > 0 {
                    stat("Betaald", settings.money(paid))
                    let diff = value - paid
                    stat(diff >= 0 ? "Winst" : "Verlies", settings.money(abs(diff)))
                }
                if !sale.isEmpty { stat("Te koop", settings.money(askValue)) }
            }
            if series.count >= 2, !settings.hideValues {
                Chart(series) {
                    LineMark(x: .value("Datum", $0.date), y: .value("EUR", $0.price)).foregroundStyle(.white)
                    AreaMark(x: .value("Datum", $0.date), y: .value("EUR", $0.price)).foregroundStyle(.white.opacity(0.18))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 54)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.gradient, in: .rect(cornerRadius: 18))
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
        }
    }

    // MARK: - Stijgers en dalers

    @ViewBuilder
    private var movers: some View {
        let changes: [(CardItem, Double)] = Set(collection.entries.map(\.productID)).compactMap { id in
            guard let item = catalog.byID[id], let c = item.weekChange, abs(c) >= 0.01 else { return nil }
            return (item, c)
        }
        let up = changes.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
        let down = changes.filter { $0.1 < 0 }.sorted { $0.1 < $1.1 }.prefix(3)
        if !up.isEmpty || !down.isEmpty {
            Section("Beweging t.o.v. 7-daags gemiddelde") {
                ForEach(Array(up) + Array(down), id: \.0.id) { item, change in
                    NavigationLink(value: item) {
                        HStack {
                            CardImage(item: item).frame(width: 34)
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Label(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())),
                                  systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(change > 0 ? .green : .red)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rij

    private func row(_ e: CollectionEntry, _ item: CardItem) -> some View {
        HStack(spacing: 12) {
            CardImage(item: item).frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2)
                HStack(spacing: 6) {
                    ConditionBadge(condition: e.condition)
                    if e.quantity > 1 { Text("\(e.quantity)×").font(.caption.weight(.semibold)) }
                    if e.forSale {
                        let review = SaleAdvisor.review(e, market: market, settings: settings)
                        Text(review.verdict.label).font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(review.verdict.color.opacity(0.18), in: .capsule)
                            .foregroundStyle(review.verdict.color)
                    } else if let set = catalog.setName(for: item) {
                        Text(set).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if e.forSale, let ask = e.askingPrice {
                    Text(settings.money(ask * Double(e.quantity))).monospacedDigit()
                    Text("vraagprijs").font(.caption2).foregroundStyle(.secondary)
                } else {
                    let unit = collection.unitValue(e, catalog: catalog)
                    Text(settings.money(unit.map { $0 * Double(e.quantity) })).monospacedDigit()
                    Text(e.myPrice == nil ? "schatting" : "jouw prijs").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
    }

    // MARK: - CSV

    private var csvURL: URL {
        var lines = ["naam;cardmarket_id;set;staat;aantal;betaald_per_kaart;mijn_prijs;vraagprijs;te_koop;waarde_per_kaart"]
        for e in collection.entries {
            let item = catalog.byID[e.productID]
            func n(_ v: Double?) -> String { v.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "" }
            lines.append([e.name.replacingOccurrences(of: ";", with: ","), String(e.productID), item.flatMap { catalog.setName(for: $0) } ?? "",
                          e.condition.rawValue, String(e.quantity), n(e.paidPrice), n(e.myPrice), n(e.askingPrice),
                          e.forSale ? "ja" : "nee", n(collection.unitValue(e, catalog: catalog))].joined(separator: ";"))
        }
        let url = URL.temporaryDirectory.appending(path: "collectie.csv")
        try? ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Kaart aan je collectie toevoegen of een bestaande regel aanpassen.
struct AddToCollectionSheet: View {
    let item: CardItem
    var existing: CollectionEntry?
    @Environment(CollectionStore.self) private var collection
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var condition: Condition = .nm
    @State private var quantity = 1
    @State private var paid: Double?
    @State private var myPrice: Double?
    @State private var forSale = false
    @State private var asking: Double?
    @State private var note = ""

    private var draft: CollectionEntry {
        CollectionEntry(productID: item.id, name: item.name, condition: condition, quantity: quantity,
                        paidPrice: paid, myPrice: myPrice, note: note, forSale: forSale, askingPrice: asking)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CardImage(item: item).frame(width: 60)
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline)
                            Text("Trend \(euro(item.mainPrice))").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Kaart") {
                    Picker("Staat", selection: $condition) {
                        ForEach(Condition.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Aantal: \(quantity)", value: $quantity, in: 1...999)
                }
                Section {
                    TextField("Betaald per kaart (EUR)", value: $paid, format: .number)
                    TextField("Jouw prijs per kaart (EUR)", value: $myPrice, format: .number)
                    ForEach(suggestions, id: \.label) { s in
                        Button("\(s.label): \(euro(s.price))") { myPrice = s.price }
                    }
                } header: {
                    Text("Waarde")
                } footer: {
                    Text("Jouw prijs bepaal je zelf. Laat je hem leeg, dan telt de app de Cardmarket-trend (alle staten) als schatting.")
                }
                Section {
                    Toggle("Te koop", isOn: $forSale)
                    if forSale {
                        TextField("Vraagprijs per kaart (EUR)", value: $asking, format: .number)
                        let review = SaleAdvisor.review(draft, market: market, settings: settings)
                        HStack {
                            Text("Beoordeling")
                            Spacer()
                            Text(review.verdict.label).fontWeight(.semibold).foregroundStyle(review.verdict.color)
                        }
                        Text(review.text).font(.footnote).foregroundStyle(.secondary)
                        if let s = review.suggested { Button("Gebruik advies: \(euro(s))") { asking = s } }
                        if let f = review.fastSale { Button("Snelle verkoop: \(euro(f))") { asking = f } }
                        if let net = review.net {
                            LabeledContent("Netto na \(settings.sellerFeePercent.formatted())% commissie", value: euro(net))
                        }
                    }
                } header: { Text("Verkoop") } footer: {
                    if forSale { Text("Het advies gebruikt de aanbiedingen die de app voor deze kaart en staat heeft opgehaald. Gebruik Marktcheck in je collectie om ze te verversen.") }
                }
                Section("Notitie") { TextField("Bijvoorbeeld: gesigneerd, 1e editie", text: $note) }
                if let existing {
                    Section { Button("Verwijder uit collectie", role: .destructive) { collection.remove(existing.id); dismiss() } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Aan collectie" : "Bewerken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Bewaar", action: save) }
            }
            .onAppear {
                if let e = existing {
                    condition = e.condition; quantity = e.quantity; paid = e.paidPrice; myPrice = e.myPrice
                    note = e.note; forSale = e.forSale; asking = e.askingPrice
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 600)
        #endif
    }

    private var suggestions: [(label: String, price: Double)] {
        var out: [(String, Double)] = []
        if let t = item.mainPrice { out.append(("Cardmarket-trend", t)) }
        if let s = market.stats(item.id, minCondition: condition) {
            out.append(("Mediaan \(condition.rawValue)+ aanbiedingen", s.median))
        }
        return out
    }

    private func save() {
        if var e = existing {
            e.condition = condition; e.quantity = quantity; e.paidPrice = paid; e.myPrice = myPrice
            e.note = note; e.forSale = forSale; e.askingPrice = asking
            collection.update(e)
        } else {
            collection.add(draft)
        }
        dismiss()
    }
}
