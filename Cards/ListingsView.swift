import SwiftUI

struct ListingsView: View {
    let item: CardItem
    @State private var loader = ListingsLoader()
    @State private var minCondition: Condition? = nil

    private var cheapestPerCondition: [(String, Listing)] {
        Dictionary(grouping: loader.listings, by: \.condition)
            .compactMap { code, items in items.min { $0.price < $1.price }.map { (code, $0) } }
            .sorted { Condition.order($0.0) < Condition.order($1.0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Minimale staat", selection: $minCondition) {
                Text("Alle").tag(Condition?.none)
                ForEach([Condition.nm, .ex, .gd, .lp]) { Text($0.rawValue + "+").tag(Condition?.some($0)) }
            }
            .pickerStyle(.segmented)
            .padding()

            if loader.status == .done {
                List {
                    Section("Goedkoopste per staat") {
                        ForEach(cheapestPerCondition, id: \.0) { code, l in
                            LabeledContent(code, value: euro(l.price))
                        }
                    }
                    Section("Aanbiedingen (\(loader.listings.count))") {
                        ForEach(loader.listings) { l in
                            HStack {
                                Text(l.condition).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: .rect(cornerRadius: 4))
                                VStack(alignment: .leading) {
                                    Text(l.seller)
                                    Text("\(l.country) · \(l.language) · \(l.quantity)×").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(euro(l.price)).monospacedDigit()
                            }
                        }
                    }
                }
                WebViewHost(webView: loader.webView).frame(height: 0)
            } else {
                Text(hint).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                WebViewHost(webView: loader.webView)
            }
        }
        .navigationTitle("Aanbiedingen")
        .onAppear { loader.load(productID: item.id, minCondition: minCondition) }
        .onChange(of: minCondition) { _, new in loader.load(productID: item.id, minCondition: new) }
        .onDisappear { loader.stop() }
    }

    private var hint: String {
        switch loader.status {
        case .needsCheck: "Cardmarket vraagt een beveiligingscontrole. Vink 'Verify you are human' hieronder zelf aan."
        case .failed: "Geen aanbiedingen gevonden of Cardmarket is veranderd. Probeer een andere staat."
        default: "Cardmarket laden…"
        }
    }
}
