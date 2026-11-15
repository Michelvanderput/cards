import SwiftUI

/// Overzicht van de officiële Cardmarket-verzendkosten naar Nederland per land van herkomst.
struct ShippingCountriesView: View {
    @Environment(AppSettings.self) private var settings
    @State private var sortByPrice = true

    private var rows: [(name: String, c: ShippingTable.Country)] {
        let list = (ShippingTable.shared?.countries ?? [:]).map { (name: $0.key, c: $0.value) }
        return sortByPrice
            ? list.sorted { ($0.c.u[0] ?? $0.c.t[0] ?? 999, $0.name) < ($1.c.u[0] ?? $1.c.t[0] ?? 999, $1.name) }
            : list.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.name) { r in
                    HStack(alignment: .firstTextBaseline) {
                        Text(AppSettings.flag(r.name))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name)
                            Text(r.c.d.map { "≈ \($0) dagen" } ?? "levertijd onbekend")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(r.c.u[0].map { "brief \(euro($0))" } ?? "geen brief").monospacedDigit()
                            Text(r.c.t.compactMap { $0 }.first.map { "aangetekend \(euro($0))" } ?? "geen aangetekend")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Naar Nederland")
                    Spacer()
                    Picker("Sorteren", selection: $sortByPrice) {
                        Text("Goedkoopst").tag(true)
                        Text("A–Z").tag(false)
                    }
                    .pickerStyle(.menu).textCase(nil)
                }
            } footer: {
                Text("""
                Tarieven van Cardmarket (verzendkostenrekenaar, uitgelezen op \(ShippingTable.shared?.fetched ?? "onbekend")), inclusief verpakkingstoeslag. \
                Brief: tot 20 g, ongeveer 4 kaarten, alleen tot €25 waarde. Aangetekend is verplicht boven €25; het getoonde bedrag is de goedkoopste aangetekende optie. \
                Meer kaarten of een hogere waarde kosten meer; de app kiest daarvoor automatisch het passende tarief.
                """)
            }
        }
        .navigationTitle("Verzendkosten per land")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
