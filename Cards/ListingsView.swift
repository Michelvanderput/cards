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
    @AppStorage("languageFilter") private var languageFilter: LanguageFilter = .defaultValue
    @AppStorage("hideGraded") private var hideGraded = true

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
        .onChange(of: hideGraded) { _, _ in loader.load(productID: item.id, minCondition: minCondition, language: languageFilter) }
        .onChange(of: languageFilter) { _, new in language = nil; loader.load(productID: item.id, minCondition: minCondition, language: new) }
        .onChange(of: loader.status) { _, new in
            if new == .done { market.recordListings(id: item.id, minCondition: minCondition, listings: loader.listings) }
        }
        .onDisappear { loader.stop() }
        .sheet(item: $selected) { l in
            if let score = scores[l.id] { ListingDetailSheet(listing: l, score: score, item: item, language: languageFilter) }
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
                Toggle("Alleen Engels", isOn: Binding(get: { languageFilter == .english },
                                                      set: { languageFilter = $0 ? .english : .all }))
                    .toggleStyle(.switch).fixedSize()
                Toggle("Verberg gegradeerd", isOn: $hideGraded).toggleStyle(.switch).fixedSize()
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
                    if loader.hiddenGradedCount > 0 {
                        Text("\(loader.hiddenGradedCount) gegradeerde aanbiedingen (PSA/BGS/CGC...) verborgen. ")
                    }
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
                if let advice = score.advice { AdviceChip(advice: advice) }
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
            if let advice = score.advice { AdviceChip(advice: advice) }
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

struct AdviceChip: View {
    let advice: DealScore.Advice
    var body: some View {
        Label(advice.label, systemImage: advice.icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(advice.color.opacity(0.14), in: .capsule)
            .foregroundStyle(advice.color)
    }
}

struct ListingDetailSheet: View {
    let listing: Listing
    let score: DealScore
    let item: CardItem
    let language: LanguageFilter
    @Environment(\.dismiss) private var dismiss
    @State private var showPhoto = false
    @State private var showMessage = false

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
                Section {
                    if let advice = score.advice {
                        Label {
                            Text(adviceText(advice))
                        } icon: {
                            Image(systemName: advice.icon).foregroundStyle(advice.color)
                        }
                    } else {
                        Text(listing.hasPhoto ? "Er is een foto beschikbaar." : "Geen foto. Vraag er zo nodig een als je twijfelt over de staat.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if listing.hasPhoto {
                        Button { showPhoto = true } label: { Label("Foto bekijken op Cardmarket", systemImage: "camera") }
                    }
                    Button { showMessage = true } label: { Label("Vraag de verkoper om een foto", systemImage: "text.bubble") }
                } header: { Text("Controleer de kaart") } footer: {
                    Text("De app verstuurt nooit berichten: je kopieert de tekst en stuurt hem zelf via Cardmarket.")
                }
                Section("Prijs") {
                    LabeledContent("Aanbieding", value: euro(listing.price))
                    LabeledContent("Verzending", value: score.shipping > 0 ? euro(score.shipping) : "niet meegeteld")
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
                    if let url = SellerMessage.profileURL(seller: listing.seller) {
                        Link(destination: url) { Label("Profiel van de verkoper", systemImage: "person.crop.circle") }
                    }
                    Link(destination: item.cardmarketURL) { Label("Open de kaart op Cardmarket", systemImage: "safari") }
                }
            }
            .navigationTitle("Aanbieding")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
            .sheet(isPresented: $showPhoto) { PhotoCheckSheet(listing: listing, item: item, language: language) }
            .sheet(isPresented: $showMessage) { PhotoRequestSheet(listing: listing, item: item) }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 640)
        #endif
    }

    private func adviceText(_ a: DealScore.Advice) -> String {
        switch a {
        case .askPhoto: "Dit is een goede prijs voor de staat die de verkoper noemt, maar er is geen foto. Vraag eerst een foto voordat je koopt."
        case .checkPhoto: "Goede prijs. Bekijk eerst de foto en let op hoeken, randen en het oppervlak."
        case .suspicious: "Opvallend ver onder de markt. Dat kan een koopje zijn, maar controleer foto, staat en verkoper extra goed."
        }
    }
}

/// Toont de Cardmarket-pagina met de rij van deze verkoper gemarkeerd, zodat je de foto zelf kunt bekijken.
struct PhotoCheckSheet: View {
    let listing: Listing
    let item: CardItem
    let language: LanguageFilter
    @Environment(\.dismiss) private var dismiss
    @State private var loader = ListingsLoader()
    @State private var found: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                WebViewHost(webView: loader.webView)
            }
            .navigationTitle("Foto bekijken")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
            .task {
                loader.load(productID: item.id, minCondition: Condition(rawValue: listing.condition), language: language)
                while loader.isPolling {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { loader.stop(); return }
                }
                found = await loader.highlight(seller: listing.seller, price: listing.price)
            }
            .onDisappear { loader.stop() }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 680)
        #endif
    }

    private var message: String {
        switch (loader.status, found) {
        case (.needsCheck, _): "Vink eerst de beveiligingscontrole aan."
        case (_, nil): "Pagina laden…"
        case (_, true?): "De rij van \(listing.seller) is gemarkeerd. Beweeg over of tik op het camera-icoontje om de foto te zien."
        case (_, false?): "Deze aanbieding is niet meer gevonden (misschien verkocht of verlopen). Zoek \(listing.seller) op de pagina."
        }
    }
}

/// Bericht om de verkoper om een foto te vragen, klaar om te kopiëren.
struct PhotoRequestSheet: View {
    let listing: Listing
    let item: CardItem
    @Environment(\.dismiss) private var dismiss
    @State private var lang: SellerMessage.Lang = .en
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Taal", selection: $lang) {
                        Text("English").tag(SellerMessage.Lang.en)
                        Text("Nederlands").tag(SellerMessage.Lang.nl)
                        Text("Deutsch").tag(SellerMessage.Lang.de)
                        Text("Français").tag(SellerMessage.Lang.fr)
                        Text("Español").tag(SellerMessage.Lang.es)
                        Text("Italiano").tag(SellerMessage.Lang.it)
                    }
                    TextEditor(text: $text).frame(minHeight: 140)
                } header: { Text("Bericht aan \(listing.seller)") } footer: {
                    Text("Kopieer het bericht en stuur het via het profiel van de verkoper op Cardmarket. De app verstuurt zelf niets.")
                }
                Section {
                    Button {
                        SellerMessage.copyToClipboard(text)
                        copied = true
                    } label: { Label(copied ? "Gekopieerd" : "Kopieer bericht", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    if let url = SellerMessage.profileURL(seller: listing.seller) {
                        Link(destination: url) { Label("Open profiel van \(listing.seller)", systemImage: "person.crop.circle") }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Foto vragen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Klaar") { dismiss() } } }
            .onAppear { lang = SellerMessage.language(forCountry: listing.country); regenerate() }
            .onChange(of: lang) { _, _ in regenerate() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
    }

    private func regenerate() {
        text = SellerMessage.make(card: item.name, condition: listing.condition, price: listing.price, lang: lang)
        copied = false
    }
}
