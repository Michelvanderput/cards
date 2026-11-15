import SwiftUI

struct ListingsView: View {
    let item: CardItem
    @Environment(MarketStore.self) private var market
    @State private var loader = ListingsLoader()
    @State private var minCondition: Condition? = nil
    @State private var language: String? = nil
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all

    private var filtered: [Listing] {
        loader.listings.filter { language == nil || $0.language == language }
    }
    private var languages: [String] {
        Array(Set(loader.listings.map(\.language))).filter { !$0.isEmpty }.sorted()
    }
    private var cheapestPerCondition: [(String, Listing)] {
        Dictionary(grouping: filtered, by: \.condition)
            .compactMap { code, items in items.min { $0.price < $1.price }.map { (code, $0) } }
            .sorted { Condition.order($0.0) < Condition.order($1.0) }
    }
    private var medians: [String: Double] { DealAnalyzer.medians(of: filtered) }
    private var needsCheck: Bool { loader.status == .needsCheck }

    var body: some View {
        VStack(spacing: 0) {
            controls
            ZStack {
                // De webweergave blijft altijd bestaan (nodig om te laden), maar is alleen zichtbaar
                // als Cardmarket een beveiligingscontrole vraagt.
                VStack(spacing: 6) {
                    Text("Cardmarket vraagt een beveiligingscontrole. Vink 'Verify you are human' hieronder zelf aan.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    WebViewHost(webView: loader.webView)
                }
                .opacity(needsCheck ? 1 : 0)
                .allowsHitTesting(needsCheck)

                if !needsCheck { content.background(.background) }
            }
        }
        .navigationTitle("Aanbiedingen")
        .onAppear { loader.load(productID: item.id, minCondition: minCondition, language: languageFilter) }
        .onChange(of: minCondition) { _, new in loader.load(productID: item.id, minCondition: new, language: languageFilter) }
        .onChange(of: loader.status) { _, new in
            if new == .done { market.recordListings(id: item.id, minCondition: minCondition, listings: loader.listings) }
        }
        .onDisappear { loader.stop() }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Minimale staat", selection: $minCondition) {
                Text("Alle").tag(Condition?.none)
                ForEach(Condition.filterChoices) { Text($0.rawValue + "+").tag(Condition?.some($0)) }
            }
            .pickerStyle(.segmented)
            if languages.count > 1 {
                Picker("Taal", selection: $language) {
                    Text("Alle talen").tag(String?.none)
                    ForEach(languages, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if loader.status == .failed && loader.listings.isEmpty {
            ContentUnavailableView("Niets gevonden", systemImage: "exclamationmark.triangle",
                                   description: Text("Cardmarket gaf geen aanbiedingen terug, of de pagina is veranderd."))
        } else if loader.listings.isEmpty && loader.status == .loading {
            ProgressView("Aanbiedingen laden…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView("Geen aanbiedingen", systemImage: "tray",
                                   description: Text("Er zijn geen aanbiedingen met dit filter."))
        } else {
            List {
                Section("Goedkoopste per staat") {
                    ForEach(cheapestPerCondition, id: \.0) { code, l in
                        LabeledContent(code, value: euro(l.price))
                    }
                }
                Section {
                    ForEach(filtered) { l in
                        HStack {
                            Text(l.condition).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: .rect(cornerRadius: 4))
                            VStack(alignment: .leading) {
                                Text(l.seller)
                                Text("\(l.country) · \(l.language) · \(l.quantity)×").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(euro(l.price)).monospacedDigit()
                                if let ref = medians[l.condition] {
                                    let deal = DealAnalyzer.rate(price: l.price, reference: ref)
                                    Text(deal.label).font(.caption2.bold()).foregroundStyle(deal.color)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Aanbiedingen (\(filtered.count))")
                } footer: {
                    Text("De beoordeling vergelijkt een aanbieding met de mediaan van aanbiedingen in dezelfde staat op deze pagina.")
                }
            }
            .opacity(loader.status == .loading ? 0.45 : 1)
            .overlay { if loader.status == .loading { ProgressView() } }
        }
    }
}
