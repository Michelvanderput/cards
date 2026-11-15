import SwiftUI

struct WatchlistView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(WatchStore.self) private var watch

    var body: some View {
        NavigationStack {
            List {
                ForEach(watch.entries) { e in
                    if let item = catalog.byID[e.id] {
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 2) {
                                CardRow(item: item)
                                if let t = e.target {
                                    Label("\(e.direction.label) \(euro(t))", systemImage: "bell")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text(e.name)
                    }
                }
                .onDelete { idx in idx.map { watch.entries[$0].id }.forEach(watch.remove) }
            }
            .overlay {
                if watch.entries.isEmpty {
                    ContentUnavailableView("Watchlist is leeg", systemImage: "bell",
                                           description: Text("Voeg kaarten toe vanuit de zoekresultaten."))
                }
            }
            .navigationTitle("Watchlist")
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
        }
    }
}
