import SwiftUI

struct SetLogo: View {
    let set: SetInfo
    var height: CGFloat = 36
    var body: some View {
        CachedImage(url: set.logoURL) { _ in
            Image(systemName: "square.stack.3d.up").foregroundStyle(.tertiary)
        }
        .frame(width: height * 2.2, height: height)
    }
}

enum SetSort: String, CaseIterable, Identifiable {
    case newest = "Nieuwste eerst", oldest = "Oudste eerst (chronologisch)", name = "A–Z"
    var id: String { rawValue }
}

struct SetsView: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var query = ""
    @AppStorage("setSort") private var setSort: SetSort = .newest
    @AppStorage("onlyNamedSets") private var onlyNamed = true

    private var sets: [SetInfo] {
        var list = catalog.sets
        if onlyNamed { list = list.filter(\.isNamed) }
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        switch setSort {
        case .newest: return list.sorted { ($0.releaseDate ?? .distantPast, $0.id) > ($1.releaseDate ?? .distantPast, $1.id) }
        case .oldest: return list.sorted { ($0.releaseDate ?? .distantFuture, $0.id) < ($1.releaseDate ?? .distantFuture, $1.id) }
        case .name: return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func subtitle(_ set: SetInfo) -> String {
        if let d = set.releaseDate { return "\(d.formatted(.dateTime.month(.abbreviated).year())) · \(set.count) kaarten" }
        return "\(set.count) kaarten"
    }

    var body: some View {
        NavigationStack {
            List(sets) { set in
                NavigationLink(value: set) {
                    HStack(spacing: 12) {
                        SetLogo(set: set)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(set.name)
                            Text(subtitle(set)).font(.caption).foregroundStyle(.secondary)
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
                        Picker("Sorteren", selection: $setSort) {
                            ForEach(SetSort.allCases) { Text($0.rawValue).tag($0) }
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
                Text(set.releaseDate.map { "\($0.formatted(.dateTime.day().month(.abbreviated).year())) · \(set.count) kaarten" } ?? "\(set.count) kaarten")
                    .font(.subheadline.weight(.medium))
                ProgressView(value: Double(owned), total: Double(max(set.count, 1))).tint(Theme.accent)
                Text("\(owned) in je collectie").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.bar)
    }
}
