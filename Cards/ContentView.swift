import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Zoeken", systemImage: "magnifyingglass") { SearchView() }
            Tab("Sets", systemImage: "square.stack.3d.up") { SetsView() }
            Tab("Collectie", systemImage: "rectangle.stack") { CollectionView() }
            Tab("Binders", systemImage: "books.vertical") { BindersView() }
            Tab("Watchlist", systemImage: "bell") { WatchlistView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(Theme.accent)
    }
}
