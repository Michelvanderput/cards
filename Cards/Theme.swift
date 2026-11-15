import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.31, blue: 0.92)
    static let accent2 = Color(red: 0.62, green: 0.30, blue: 0.90)
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Beeldverhouding van een Pokémon-kaart (63 × 88 mm).
    static let cardRatio: CGFloat = 63.0 / 88.0
    static let binderColors: [Color] = [
        Color(red: 0.36, green: 0.31, blue: 0.92), Color(red: 0.90, green: 0.30, blue: 0.35),
        Color(red: 0.12, green: 0.62, blue: 0.55), Color(red: 0.95, green: 0.62, blue: 0.15),
        Color(red: 0.20, green: 0.50, blue: 0.90), Color(red: 0.30, green: 0.30, blue: 0.36),
    ]
}

extension Condition {
    var color: Color {
        switch self {
        case .mt: .teal
        case .nm: .green
        case .ex: .mint
        case .gd: .yellow
        case .lp: .orange
        case .pl: .red
        case .po: .brown
        }
    }
}

struct ConditionBadge: View {
    let condition: Condition
    var body: some View {
        Text(condition.rawValue)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(condition.color.opacity(0.22), in: .capsule)
            .foregroundStyle(condition.color)
    }
}

/// Kaartafbeelding met nette placeholder en afgeronde hoeken.
struct CardImage: View {
    let item: CardItem
    var quality: CardMap.Quality = .low
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        CachedImage(url: catalog.imageURL(for: item, quality: quality)) { failed in
            placeholder(systemImage: failed ? "photo" : nil)
        }
        .aspectRatio(Theme.cardRatio, contentMode: .fit)
        .clipShape(.rect(cornerRadius: quality == .high ? 14 : 6))
    }

    private func placeholder(systemImage: String?) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            .overlay {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.tertiary) }
                else { ProgressView().controlSize(.small) }
            }
    }
}

struct CardRow: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    var body: some View {
        HStack(spacing: 12) {
            CardImage(item: item).frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(2)
                HStack(spacing: 6) {
                    if let set = catalog.setName(for: item) {
                        Text([set, catalog.cardNumber(for: item)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VariantChip(item: item)
                }
            }
            Spacer()
            Text(euro(item.mainPrice)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Tegel voor rasterweergaven.
struct CardTile: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    var body: some View {
        VStack(spacing: 6) {
            CardImage(item: item)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    Text(euro(item.mainPrice))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(5)
                }
            Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            VariantChip(item: item)
        }
    }
}

/// Toont de variant ("Reverse holo", "1e editie") en, bij gegroepeerde kaarten, hoeveel uitvoeringen er zijn.
struct VariantChip: View {
    let item: CardItem
    @Environment(CatalogStore.self) private var catalog
    @AppStorage("groupVariants") private var groupVariants = true

    var body: some View {
        let count = catalog.variants(of: item).count
        if let label = catalog.variantLabel(for: item) {
            chip(label, color: .purple)
        } else if groupVariants, count > 1 {
            chip("\(count) uitvoeringen", color: .secondary)
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule).foregroundStyle(color)
    }
}

/// Raster met kaarten die naar het detail navigeren.
struct CardGrid: View {
    let items: [CardItem]
    var minWidth: CGFloat = 110

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 14)], spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item) { CardTile(item: item) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

func euro(_ value: Double?) -> String {
    guard let value else { return "–" }
    return value.formatted(.currency(code: "EUR"))
}
