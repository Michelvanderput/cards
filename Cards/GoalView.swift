import SwiftUI

struct GoalView: View {
    let goal: Goal
    @Environment(CatalogStore.self) private var catalog
    @Environment(CollectionStore.self) private var collection
    @Environment(WatchStore.self) private var watch
    @Environment(ConditionChecker.self) private var checker
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .defaultValue
    @State private var tab: Tab = .missing
    @State private var minCondition: Condition = .ex
    @State private var showSearch = false
    @State private var searchLimit: Int?
    @State private var addedCount: Int?

    enum Tab: String, CaseIterable, Identifiable {
        case missing = "Ontbreekt", deals = "Beste deals", all = "Alles"
        var id: String { rawValue }
    }

    private var cards: [CardItem] { catalog.goalCards(goal) }
    private var ownedIDs: Set<Int> { Set(collection.entries.map(\.productID)) }
    private var missing: [CardItem] { cards.filter { !catalog.isOwned($0, ownedIDs: ownedIDs) } }

    var body: some View {
        let cards = cards
        let missing = missing
        List {
            summary(cards, missing)
            Section {
                Picker("Weergave", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
            }
            switch tab {
            case .missing: cardsSection(missing, empty: "Je hebt alles. Gefeliciteerd!")
            case .all: cardsSection(cards, empty: "Geen kaarten gevonden.")
            case .deals: dealsSection(missing)
            }
        }
        .navigationTitle(goal.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Minimale staat", selection: $minCondition) {
                        ForEach(Condition.filterChoices) { Text($0.rawValue + " of beter").tag($0) }
                    }
                    Button("Zet ontbrekende kaarten op de watchlist", systemImage: "bell.badge") { addToWatchlist(missing) }
                    Divider()
                    Button("Zoek beste deals (eerste 25)", systemImage: "magnifyingglass") { startSearch(limit: 25) }
                    Button("Zoek beste deals (alle \(missing.count))", systemImage: "magnifyingglass.circle") { startSearch(limit: nil) }
                } label: { Label("Acties", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showSearch) {
            CheckSheet(title: "Beste deals zoeken") {
                let jobs = Array(missing.prefix(searchLimit ?? missing.count))
                    .map { (productID: $0.id, name: $0.name, condition: Optional(minCondition)) }
                await checker.refreshMarket(jobs: jobs, language: languageFilter, market: market, interactive: true)
                tab = .deals
            }
        }
    }

    private func startSearch(limit: Int?) { searchLimit = limit; showSearch = true }

    // MARK: - Samenvatting

    private func summary(_ cards: [CardItem], _ missing: [CardItem]) -> some View {
        let owned = cards.count - missing.count
        let cost = missing.reduce(0) { $0 + ($1.mainPrice ?? 0) }
        // Echte kosten: goedkoopste Engelse aanbieding (gekozen staat of beter) voor de kaarten die we gecontroleerd hebben.
        let priced: [Double] = missing.compactMap { item in
            checker.lastListings[item.id]?.filter { Condition.order($0.condition) <= minCondition.level }.map(\.price).min()
        }
        let realCost = priced.reduce(0, +)
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(goal.subtitle).font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: Double(owned), total: Double(max(cards.count, 1))).tint(Theme.accent)
                HStack {
                    stat("In bezit", "\(owned) / \(cards.count)")
                    Spacer()
                    stat("Trendschatting", "≈ \(euro(cost))")
                    Spacer()
                    stat("Op watchlist", "\(missing.filter { watch.isWatching($0.id) }.count)")
                }
                if !priced.isEmpty {
                    Label("Op basis van echte aanbiedingen (\(minCondition.rawValue)+, Engels): \(euro(realCost)) voor \(priced.count) van \(missing.count) ontbrekende kaarten", systemImage: "eurosign.circle")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                Text("De trendschatting telt alle staten en talen mee en ligt voor Engelse \(minCondition.rawValue)-kaarten meestal veel lager. Zoek beste deals voor de echte prijzen.")
                    .font(.caption2).foregroundStyle(.secondary)
                if RateLimitState.shared.isCoolingDown {
                    Label(RateLimitState.shared.message, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                }
                if let addedCount { Text("\(addedCount) kaarten toegevoegd aan je watchlist met een koopjes-melding (\(minCondition.rawValue) of beter).").font(.caption).foregroundStyle(.green) }
                if cards.isEmpty { Text("De catalogus is nog niet geladen.").font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: - Kaarten

    @ViewBuilder
    private func cardsSection(_ list: [CardItem], empty: String) -> some View {
        if list.isEmpty {
            Section { Text(empty).foregroundStyle(.secondary) }
        } else {
            Section("\(list.count) kaarten") {
                ForEach(list) { item in
                    NavigationLink(value: item) {
                        HStack {
                            CardRow(item: item)
                            if catalog.isOwned(item, ownedIDs: ownedIDs) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if watch.isWatching(item.id) { Image(systemName: "bell.fill").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Beste deals

    private struct Deal: Identifiable {
        let id: Int
        let item: CardItem
        let listing: Listing
        let score: DealScore
    }

    private func bestDeals(_ list: [CardItem]) -> [Deal] {
        var out: [Deal] = []
        for item in list {
            guard let all = checker.lastListings[item.id] else { continue }
            let relevant = all.filter { Condition.order($0.condition) <= minCondition.level }
            guard !relevant.isEmpty else { continue }
            let scores = DealEngine.analyze(relevant, settings: settings, tcgplayerEUR: market.tcgplayerEUR(item.id), trend: item.mainPrice)
            if let best = relevant.max(by: { (scores[$0.id]?.value ?? 0) < (scores[$1.id]?.value ?? 0) }), let sc = scores[best.id] {
                out.append(Deal(id: item.id, item: item, listing: best, score: sc))
            }
        }
        return out.sorted { $0.score.value > $1.score.value }
    }

    @ViewBuilder
    private func dealsSection(_ missing: [CardItem]) -> some View {
        let deals = bestDeals(missing)
        let checked = missing.filter { checker.lastListings[$0.id] != nil }.count
        if deals.isEmpty {
            Section {
                Text("Nog geen aanbiedingen opgehaald. Kies Acties → Zoek beste deals. De app laadt dan per ontbrekende kaart de Engelse aanbiedingen (\(minCondition.rawValue) of beter) en rangschikt de beste.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(deals) { d in
                    NavigationLink(value: d.item) {
                        HStack(spacing: 10) {
                            ScoreRing(score: d.score, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.item.name).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let c = Condition(rawValue: d.listing.condition) { ConditionBadge(condition: c) }
                                    Text("\(AppSettings.flag(d.listing.country)) \(d.listing.seller)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if let advice = d.score.advice { AdviceChip(advice: advice) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(euro(d.listing.price)).monospacedDigit().font(.headline)
                                if d.score.shipping > 0 { Text("totaal \(euro(d.score.total))").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                                if let disc = d.score.discount, disc >= 0.03 {
                                    Text("−\(Int((disc * 100).rounded()))%").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Beste aanbieding per kaart (\(checked) van \(missing.count) gecontroleerd)")
            } footer: {
                Text("Per kaart de aanbieding met de hoogste dealscore, alleen Engels en \(minCondition.rawValue) of beter, inclusief verzendkosten.")
            }
        }
    }

    // MARK: - Watchlist

    private func addToWatchlist(_ list: [CardItem]) {
        var n = 0
        for item in list {
            if !watch.isWatching(item.id) { watch.add(item); n += 1 }
            // Koopjes-melding op de gekozen staat (zonder doelprijs): de app meldt een uitzonderlijke aanbieding.
            watch.setAlert(item.id, target: nil, direction: .below, minCondition: minCondition, dealAlert: true)
        }
        addedCount = n
    }
}
