import SwiftUI
import Charts

struct DetailView: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch
    @Environment(HistoryStore.self) private var history
    @Environment(MarketStore.self) private var market
    @Environment(CollectionStore.self) private var collection
    @Environment(BinderStore.self) private var binders
    @State private var showAlert = false
    @State private var showAdd = false
    @State private var toast: String?

    private var current: CardItem { catalog.byID[item.id] ?? item }

    var body: some View {
        List {
            hero
            Section {
                actions
            }
            .listRowBackground(Color.clear)
            .listRowInsets(.init())

            let siblings = catalog.variants(of: current)
            if siblings.count > 1 {
                Section {
                    ForEach(siblings) { v in
                        NavigationLink(value: v) {
                            HStack {
                                CardImage(item: v).frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(catalog.variantLabel(for: v) ?? "Gewone kaart")
                                    if v.id == item.id { Text("Deze uitvoering").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(euro(v.mainPrice)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Uitvoeringen in deze set") } footer: {
                    Text("Cardmarket heeft voor deze kaart meerdere producten, bijvoorbeeld normaal, reverse holo of een ander patroon. Elk heeft een eigen prijs.")
                }
            }
            Section("Prijsverloop (trend)") {
                let pts = history.points[item.id] ?? []
                if pts.count >= 2 {
                    Chart(pts) {
                        AreaMark(x: .value("Datum", $0.date), y: .value("EUR", $0.price))
                            .foregroundStyle(Theme.accent.opacity(0.15))
                        LineMark(x: .value("Datum", $0.date), y: .value("EUR", $0.price))
                            .foregroundStyle(Theme.accent)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 140)
                } else {
                    Text("De geschiedenis wordt vanaf nu elke dag bijgehouden voor kaarten die je bekijkt of volgt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Cardmarket (trend, alle staten)", value: euro(current.mainPrice))
                if current.priceIsUncertain {
                    Label("De trend in de prijsgids wijkt sterk af van het gemiddelde. De app toont daarom het 7-daags gemiddelde.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
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
                if let e = watch.entry(item.id), let summary = e.alertSummary {
                    LabeledContent("Alert", value: summary)
                }
                NavigationLink("Aanbiedingen per staat") { ListingsView(item: current) }
                Link("Open op Cardmarket", destination: current.cardmarketURL)
            }
        }
        .navigationTitle(item.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { history.record(id: item.id, price: current.mainPrice) }
        .task { await market.fetchCrossMarket(item: item, map: catalog.map) }
        .sheet(isPresented: $showAlert) { AlertSheet(item: current) }
        .sheet(isPresented: $showAdd) { AddToCollectionSheet(item: current) }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule).padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
    }

    // MARK: - Onderdelen

    private var hero: some View {
        Section {
            VStack(spacing: 10) {
                CardImage(item: current, quality: .high)
                    .frame(maxHeight: 380)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, y: 8)
                VStack(spacing: 2) {
                    Text(euro(current.mainPrice)).font(.title.weight(.bold)).monospacedDigit()
                    if let set = catalog.setName(for: current) {
                        Text(set).font(.subheadline).foregroundStyle(.secondary)
                    }
                    let owned = collection.count(of: item.id)
                    if owned > 0 {
                        Label("\(owned)× in je collectie", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(
                LinearGradient(colors: [Theme.accent.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            actionButton("Collectie", "plus.rectangle.on.rectangle") { showAdd = true }
            Menu {
                if binders.binders.isEmpty { Text("Maak eerst een binder") }
                ForEach(binders.binders) { b in
                    Button(b.name) {
                        toast = binders.addCard(b.id, productID: item.id) ? "Toegevoegd aan \(b.name)" : "\(b.name) is vol"
                        hideToast()
                    }
                }
            } label: { actionLabel("Binder", "books.vertical") }
            .buttonStyle(.plain)
            if watch.isWatching(item.id) {
                actionButton("Alert", "bell.fill") { showAlert = true }
            } else {
                actionButton("Volgen", "bell") { watch.add(item); showAlert = true }
            }
        }
        .padding(.horizontal)
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon) }.buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: 12))
        .foregroundStyle(Theme.accent)
    }

    private func hideToast() {
        Task { try? await Task.sleep(for: .seconds(2)); toast = nil }
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
