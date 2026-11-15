import SwiftUI

struct SearchView: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let results = catalog.search(query)
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
