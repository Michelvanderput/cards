import SwiftUI
import Charts

struct DetailView: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch
    @Environment(HistoryStore.self) private var history
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
            Section("Cardmarket-gemiddelde, alle staten (EUR)") { rows(current.normal) }
            if !current.holo.isEmpty {
                Section("Holo / foil") { rows(current.holo) }
            }
            Section {
                if let e = watch.entry(item.id) {
                    if let t = e.target {
                        LabeledContent("Alert", value: "\(e.direction.label) \(euro(t))")
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
    @Environment(\.dismiss) private var dismiss
    @State private var direction: AlertDirection = .below
    @State private var target: Double?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Melden wanneer prijs", selection: $direction) {
                    ForEach(AlertDirection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Prijs in EUR", value: $target, format: .number)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text("Nu: \(euro(item.mainPrice))").foregroundStyle(.secondary)
            }
            .navigationTitle("Prijsalert")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuleer") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bewaar") {
                        watch.setAlert(item.id, target: target, direction: direction)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let e = watch.entry(item.id) { direction = e.direction; target = e.target }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 220)
        #endif
    }
}
