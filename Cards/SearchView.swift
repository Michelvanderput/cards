import SwiftUI

enum SearchSort: String, CaseIterable, Identifiable {
    case priceDesc = "Prijs: hoog–laag", priceAsc = "Prijs: laag–hoog", name = "Naam"
    var id: String { rawValue }
}

struct SearchView: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var query = ""
    @State private var sort: SearchSort = .priceDesc
    @State private var expansion: Int? = nil
    @State private var onlyPriced = false

    private func results(from all: [CardItem]) -> [CardItem] {
        var out = all
        if let expansion { out = out.filter { $0.expansionId == expansion } }
        if onlyPriced { out = out.filter { $0.mainPrice != nil } }
        switch sort {
        case .priceDesc: out.sort { ($0.mainPrice ?? -1) > ($1.mainPrice ?? -1) }
        case .priceAsc: out.sort { ($0.mainPrice ?? .infinity) < ($1.mainPrice ?? .infinity) }
        case .name: out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Array(out.prefix(300))
    }

    /// Sets die in de huidige treffers voorkomen, met aantal.
    private func setOptions(from all: [CardItem]) -> [(id: Int, name: String, count: Int)] {
        Dictionary(grouping: all, by: \.expansionId)
            .compactMap { id, items in catalog.map.sets[id].map { (id: id, name: $0, count: items.count) } }
            .sorted { $0.count > $1.count }
            .prefix(40).map { $0 }
    }

    var body: some View {
        NavigationStack {
            let all = catalog.searchAll(query)
            let results = results(from: all)
            List(results) { item in
                NavigationLink(value: item) { CardRow(item: item) }
            }
            .overlay {
                if catalog.items.isEmpty {
                    ContentUnavailableView {
                        if catalog.isLoading { ProgressView("Prijzen laden…") }
                        else { Label("Geen data", systemImage: "icloud.slash") }
                    } description: {
                        Text(catalog.errorMessage ?? "")
                    }
                } else if query.isEmpty {
                    ContentUnavailableView("Zoek een kaart", systemImage: "magnifyingglass",
                                           description: Text("\(catalog.items.count) kaarten beschikbaar"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Zoek op kaartnaam")
            .navigationTitle("Cards")
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sorteren", selection: $sort) {
                            ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Alleen met prijs", isOn: $onlyPriced)
                        Picker("Set", selection: $expansion) {
                            Text("Alle sets").tag(Int?.none)
                            ForEach(setOptions(from: all), id: \.id) { Text("\($0.name) (\($0.count))").tag(Int?.some($0.id)) }
                        }
                    } label: {
                        Label("Filter", systemImage: (expansion != nil || onlyPriced) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await catalog.refresh() } } label: {
                        if catalog.isLoading { ProgressView().controlSize(.small) }
                        else { Label("Ververs", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let d = catalog.lastUpdated {
                    Text("Cardmarket-prijzen bijgewerkt \(d.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
        }
    }
}
