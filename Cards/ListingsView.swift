import SwiftUI

enum ListingSort: String, CaseIterable, Identifiable {
    case bestDeal = "Beste deal", price = "Prijs", total = "Totaalprijs", delivery = "Levertijd"
    var id: String { rawValue }
}

struct ListingsView: View {
    let item: CardItem
    @Environment(MarketStore.self) private var market
    @Environment(AppSettings.self) private var settings
    @State private var loader = ListingsLoader()
    @State private var minCondition: Condition? = nil
    @State private var language: String? = nil
    @State private var sort: ListingSort = .bestDeal
    @State private var selected: Listing?
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .all

    private var filtered: [Listing] {
        loader.listings.filter { language == nil || $0.language == language }
    }
    private var languages: [String] {
        Array(Set(loader.listings.map(\.language))).filter { !$0.isEmpty }.sorted()
    }
    private var needsCheck: Bool { loader.status == .needsCheck }

    var body: some View {
        let scores = DealEngine.analyze(filtered, settings: settings, tcgplayerEUR: market.tcgplayerEUR(item.id), trend: item.mainPrice)
        VStack(spacing: 0) {
            controls
            ZStack {
                // De webweergave blijft altijd bestaan (nodig om te laden), maar is alleen zichtbaar
                // als Cardmarket een beveiligingscontrole vraagt.
                VStack(spacing: 6) {
                    Text("Cardmarket vraagt een beveiligingscontrole. Vink 'Verify you are human' hieronder zelf aan.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    WebViewHost(webView: loader.webView)
                }
                .opacity(needsCheck ? 1 : 0)
                .allowsHitTesting(needsCheck)

                if !needsCheck { content(scores).background(.background) }
            }
        }
        .navigationTitle("Aanbiedingen")
        .onAppear { loader.load(productID: item.id, minCondition: minCondition, language: languageFilter) }
        .onChange(of: minCondition) { _, new in loader.load(productID: item.id, minCondition: new, language: languageFilter) }
        .onChange(of: loader.status) { _, new in
            if new == .done { market.recordListings(id: item.id, minCondition: minCondition, listings: loader.listings) }
        }
        .onDisappear { loader.stop() }
        .sheet(item: $selected) { l in
            if let score = scores[l.id] { ListingDetailSheet(listing: l, score: score, item: item) }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Minimale staat", selection: $minCondition) {
                Text("Alle").tag(Condition?.none)
                ForEach(Condition.filterChoices) { Text($0.rawValue + "+").tag(Condition?.some($0)) }
            }
            .pickerStyle(.segmented)
            HStack {
                if languages.count > 1 {
                    Picker("Taal", selection: $language) {
                        Text("Alle talen").tag(String?.none)
                        ForEach(languages, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Spacer()
                Picker("Sorteren", selection: $sort) {
                    ForEach(ListingSort.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .padding()
    }

    private func sorted(_ scores: [UUID: DealScore]) -> [Listing] {
        switch sort {
        case .bestDeal: filtered.sorted { (scores[$0.id]?.value ?? 0) > (scores[$1.id]?.value ?? 0) }
        case .price: filtered.sorted { $0.price < $1.price }
        case .total: filtered.sorted { (scores[$0.id]?.total ?? $0.price) < (scores[$1.id]?.total ?? $1.price) }
        case .delivery: filtered.sorted { ($0.deliveryDays ?? 99) < ($1.deliveryDays ?? 99) }
        }
    }

    @ViewBuilder
    private func content(_ scores: [UUID: DealScore]) -> some View {
        if loader.status == .failed && loader.listings.isEmpty {
            ContentUnavailableView("Niets gevonden", systemImage: "exclamationmark.triangle",
                                   description: Text("Cardmarket gaf geen aanbiedingen terug, of de pagina is veranderd."))
        } else if loader.listings.isEmpty && loader.status == .loading {
            ProgressView("Aanbiedingen laden…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView("Geen aanbiedingen", systemImage: "tray",
                                   description: Text("Er zijn geen aanbiedingen met dit filter."))
        } else {
            let best = filtered.sorted { (scores[$0.id]?.value ?? 0) > (scores[$1.id]?.value ?? 0) }
                .prefix(3).filter { (scores[$0.id]?.value ?? 0) >= 62 }
            List {
                if !best.isEmpty {
                    Section("Beste deals") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(best)) { l in
                                    if let s = scores[l.id] {
                                        Button { selected = l } label: { DealCard(listing: l, score: s) }.buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
                Section("Goedkoopste per staat") {
                    ForEach(cheapestPerCondition, id: \.0) { code, l in
                        LabeledContent(code, value: euro(l.price))
                    }
                }
                Section {
                    ForEach(sorted(scores)) { l in
                        if let s = scores[l.id] {
                            Button { selected = l } label: { ListingRow(listing: l, score: s) }.buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Aanbiedingen (\(filtered.count))")
                } footer: {
                    Text("De dealscore weegt prijs (incl. geschatte verzending) tegenover de mediaan in dezelfde staat, de verkoper, een foto, levertijd en TCGplayer. Het is een richtlijn, geen garantie.")
                }
            }
            .opacity(loader.status == .loading ? 0.45 : 1)
            .overlay { if loader.status == .loading { ProgressView() } }
        }
    }

    private var cheapestPerCondition: [(String, Listing)] {
        Dictionary(grouping: filtered, by: \.condition)
            .compactMap { code, items in items.min { $0.price < $1.price }.map { (code, $0) } }
            .sorted { Condition.order($0.0) < Condition.order($1.0) }
    }
}

// MARK: - Onderdelen

/// Ronde dealmeter met score.
struct ScoreRing: View {
    let score: DealScore
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().stroke(score.level.color.opacity(0.2), lineWidth: size * 0.12)
            Circle().trim(from: 0, to: CGFloat(score.value) / 100)
                .stroke(score.level.color, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score.value)").font(.system(size: size * 0.36, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

struct DealBadge: View {
    let level: Deal
    var body: some View {
        Text(level.label).font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(level.color.opacity(0.18), in: .capsule)
            .foregroundStyle(level.color)
    }
}

struct SellerLine: View {
    let listing: Listing
    var body: some View {
        HStack(spacing: 4) {
            Text(AppSettings.flag(listing.country))
            Text(listing.seller).lineLimit(1)
            if let star = ratingStars { Text(star).foregroundStyle(.yellow) }
        }
    }
    private var ratingStars: String? {
        switch listing.sellerRating {
        case "outstanding": "★★★★★"
        case "verygood": "★★★★"
        case "good": "★★★"
        case "average": "★★"
        case "bad", "poor": "★"
        default: nil
        }
    }
}

struct ListingRow: View {
    let listing: Listing
    let score: DealScore
    var body: some View {
        HStack(spacing: 12) {
            ScoreRing(score: score)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let c = Condition(rawValue: listing.condition) { ConditionBadge(condition: c) }
                    DealBadge(level: score.level)
                }
                SellerLine(listing: listing).font(.subheadline)
                HStack(spacing: 8) {
                    Text(listing.language).lineLimit(1)
                    if listing.quantity > 1 { Text("\(listing.quantity)×") }
                    if let d = listing.deliveryDays { Label("\(d) d", systemImage: "shippingbox") }
                    if listing.hasPhoto { Label("foto", systemImage: "camera.fill") }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(euro(listing.price)).font(.headline).monospacedDigit()
                if score.shipping > 0 {
                    Text("totaal \(euro(score.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let d = score.discount, abs(d) >= 0.03 {
                    Text(d > 0 ? "−\(Int((d * 100).rounded()))%" : "+\(Int((-d * 100).rounded()))%")
                        .font(.caption.weight(.semibold)).foregroundStyle(d > 0 ? .green : .orange)
                }
            }
        }
        .contentShape(.rect)
    }
}

/// Grote kaart voor de beste deals bovenaan.
struct DealCard: View {
    let listing: Listing
    let score: DealScore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ScoreRing(score: score, size: 50)
                Spacer()
                DealBadge(level: score.level)
            }
            Text(euro(listing.price)).font(.title2.weight(.bold)).monospacedDigit()
            Text(score.shipping > 0 ? "totaal \(euro(score.total))" : " ").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let c = Condition(rawValue: listing.condition) { ConditionBadge(condition: c) }
                Text(listing.language).font(.caption).lineLimit(1)
            }
            SellerLine(listing: listing).font(.caption)
            if let d = score.discount, d > 0.03 {
                Text("\(Int((d * 100).rounded()))% onder de markt").font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
        }
        .padding(14)
        .frame(width: 190, alignment: .leading)
        .background(score.level.color.opacity(0.10), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(score.level.color.opacity(0.45), lineWidth: 1.5))
    }
}

struct ListingDetailSheet: View {
    let listing: Listing
    let score: DealScore
    let item: CardItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ScoreRing(score: score, size: 78)
                        VStack(alignment: .leading, spacing: 4) {
                            DealBadge(level: score.level)
                            Text(euro(listing.price)).font(.title.weight(.bold)).monospacedDigit()
                            SellerLine(listing: listing).font(.subheadline)
                        }
                    }
                }
                Section("Prijs") {
                    LabeledContent("Aanbieding", value: euro(listing.price))
                    LabeledContent("Verzending (schatting)", value: score.shipping > 0 ? euro(score.shipping) : "niet meegeteld")
                    LabeledContent("Totaal", value: euro(score.total)).fontWeight(.semibold)
                    if let ref = score.reference { LabeledContent("Mediaan \(listing.condition) (totaal)", value: euro(ref)) }
                }
                Section("Waarom deze score") {
                    ForEach(score.factors) { f in
                        Label {
                            Text(f.text)
                        } icon: {
                            Image(systemName: f.positive == true ? "checkmark.circle.fill" : f.positive == false ? "exclamationmark.circle.fill" : "circle")
                                .foregroundStyle(f.positive == true ? .green : f.positive == false ? .orange : .secondary)
                        }
                    }
                }
                Section("Verkoper") {
                    if let n = listing.sales { LabeledContent("Verkopen", value: n.formatted()) }
                    if let n = listing.availableItems { LabeledContent("Artikelen te koop", value: n.formatted()) }
                    if let d = listing.deliveryDays { LabeledContent("Levertijd naar jou", value: "≈ \(d) dagen") }
                    Link(destination: item.cardmarketURL) {
                        Label(listing.hasPhoto ? "Bekijk de foto van de verkoper op Cardmarket" : "Open de kaart op Cardmarket",
                              systemImage: listing.hasPhoto ? "camera" : "safari")
                    }
                }
            }
            .navigationTitle("Aanbieding")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }
}
