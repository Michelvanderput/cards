import SwiftUI

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
