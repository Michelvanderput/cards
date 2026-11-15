import SwiftUI

struct SetLogo: View {
    let set: SetInfo
    var height: CGFloat = 36
    var body: some View {
        AsyncImage(url: set.logoURL) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { Image(systemName: "square.stack.3d.up").foregroundStyle(.tertiary) }
        }
        .frame(width: height * 2.2, height: height)
    }
}

struct SetsView: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var query = ""
    @State private var sortNewest = true
    @AppStorage("onlyNamedSets") private var onlyNamed = true

    private var sets: [SetInfo] {
        var list = catalog.sets
        if onlyNamed { list = list.filter(\.isNamed) }
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return sortNewest ? list : list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(sets) { set in
                NavigationLink(value: set) {
                    HStack(spacing: 12) {
                        SetLogo(set: set)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.name)
                            Text("\(set.count) kaarten").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay { if catalog.items.isEmpty { ProgressView() } }
            .searchable(text: $query, prompt: "Zoek een set")
            .navigationTitle("Sets")
            .navigationDestination(for: SetInfo.self) { SetDetailView(set: $0) }
            .navigationDestination(for: CardItem.self) { DetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sorteren", selection: $sortNewest) {
                            Text("Nieuwste eerst").tag(true)
                            Text("A–Z").tag(false)
                        }
                        Toggle("Alleen sets met naam", isOn: $onlyNamed)
                    } label: { Label("Opties", systemImage: "line.3.horizontal.decrease.circle") }
                }
            }
        }
    }
}

struct SetDetailView: View {
    let set: SetInfo
    @Environment(CatalogStore.self) private var catalog
    @Environment(CollectionStore.self) private var collection
    @State private var query = ""
    @State private var sort: SearchSort = .priceDesc
    @AppStorage("gridMode") private var gridMode = true

    private var items: [CardItem] {
        var list = catalog.itemsBySet[set.id] ?? []
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        switch sort {
        case .priceDesc: list.sort { ($0.mainPrice ?? -1) > ($1.mainPrice ?? -1) }
        case .priceAsc: list.sort { ($0.mainPrice ?? .infinity) < ($1.mainPrice ?? .infinity) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private var owned: Int {
        let ids = Set((catalog.itemsBySet[set.id] ?? []).map(\.id))
        return Set(collection.entries.map(\.productID)).intersection(ids).count
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            header
            if gridMode { CardGrid(items: items) }
            else { List(items) { item in NavigationLink(value: item) { CardRow(item: item) } } }
        }
        .searchable(text: $query, prompt: "Zoek in \(set.name)")
        .navigationTitle(set.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { gridMode.toggle() } label: { Label("Weergave", systemImage: gridMode ? "list.bullet" : "square.grid.2x2") }
                Menu {
                    Picker("Sorteren", selection: $sort) { ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) } }
                } label: { Label("Sorteren", systemImage: "arrow.up.arrow.down") }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SetLogo(set: set, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(set.count) kaarten").font(.subheadline.weight(.medium))
                ProgressView(value: Double(owned), total: Double(max(set.count, 1))).tint(Theme.accent)
                Text("\(owned) in je collectie").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.bar)
    }
}
