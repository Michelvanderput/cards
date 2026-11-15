import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SearchView()
                .tabItem { Label("Zoeken", systemImage: "magnifyingglass") }
            WatchlistView()
                .tabItem { Label("Watchlist", systemImage: "bell") }
        }
    }
}

func euro(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.currency(code: "EUR"))
}

struct CardImage: View {
    let item: CardItem
    var quality: CardMap.Quality = .low
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        AsyncImage(url: catalog.imageURL(for: item, quality: quality)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            case .failure: placeholder
            default: placeholder.overlay { ProgressView().controlSize(.small) }
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
    }
}

struct CardRow: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    var body: some View {
        HStack(spacing: 12) {
            CardImage(item: item).frame(width: 44, height: 62)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(2)
                if let set = catalog.setName(for: item) {
                    Text(set).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(euro(item.mainPrice)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
