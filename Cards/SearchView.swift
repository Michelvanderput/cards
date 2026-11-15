import SwiftUI

enum SearchSort: String, CaseIterable, Identifiable {
    case priceDesc = "Prijs: hoog–laag", priceAsc = "Prijs: laag–hoog", name = "Naam"
    var id: String { rawValue }
}

struct SearchView: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var query = ""
    @State private var sort: SearchSort = .priceDesc
    @State private var setFilter: String? = nil
    @State private var onlyPriced = false
    @State private var showSettings = false
    @AppStorage("gridMode") private var gridMode = true

    private func results(from all: [CardItem]) -> [CardItem] {
        var out = all
        if let setFilter { out = out.filter { catalog.map.sets[$0.expansionId] == setFilter } }
        if onlyPriced { out = out.filter { $0.mainPrice != nil } }
        switch sort {
        case .priceDesc: out.sort { ($0.mainPrice ?? -1) > ($1.mainPrice ?? -1) }
        case .priceAsc: out.sort { ($0.mainPrice ?? .infinity) < ($1.mainPrice ?? .infinity) }
        case .name: out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Array(out.prefix(300))
    }

    /// Sets die in de huidige treffers voorkomen, met aantal.
    private func setOptions(from all: [CardItem]) -> [(name: String, count: Int)] {
        Dictionary(grouping: all.compactMap { catalog.map.sets[$0.expansionId] }, by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(40).map { $0 }
    }

    var body: some View {
        NavigationStack {
            let all = catalog.searchAll(query)
            let results = results(from: all)
            Group {
                if gridMode { CardGrid(items: results) }
                else { List(results) { item in NavigationLink(value: item) { CardRow(item: item) } } }
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
                                           description: Text("\(catalog.items.count.formatted()) kaarten beschikbaar. Of blader via Sets."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Zoek op kaartnaam of set")
            .navigationTitle("Cards")
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { gridMode.toggle() } label: {
                        Label(gridMode ? "Lijst" : "Raster", systemImage: gridMode ? "list.bullet" : "square.grid.2x2")
                    }
                    Menu {
                        Picker("Sorteren", selection: $sort) {
                            ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Alleen met prijs", isOn: $onlyPriced)
                        Picker("Set", selection: $setFilter) {
                            Text("Alle sets").tag(String?.none)
                            ForEach(setOptions(from: all), id: \.name) { Text("\($0.name) (\($0.count))").tag(String?.some($0.name)) }
                        }
                    } label: {
                        Label("Filter", systemImage: (setFilter != nil || onlyPriced) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    Button { Task { await catalog.refresh() } } label: {
                        if catalog.isLoading { ProgressView().controlSize(.small) }
                        else { Label("Ververs", systemImage: "arrow.clockwise") }
                    }
                    .keyboardShortcut("r")
                    #if os(iOS)
                    Button { showSettings = true } label: { Label("Instellingen", systemImage: "gearshape") }
                    #endif
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let d = catalog.lastUpdated {
                    Text("Cardmarket-prijzen bijgewerkt \(d.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}
