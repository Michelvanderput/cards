import SwiftUI

/// Uitkomst van de dealbeoordeling voor één aanbieding.
struct DealScore {
    struct Factor: Identifiable {
        let id = UUID()
        let text: String
        let positive: Bool?   // nil = neutraal
    }
    let value: Int           // 0–100
    let level: Deal
    let shipping: Double
    let total: Double        // prijs + geschatte verzending
    let reference: Double?   // mediaan totaalprijs van dezelfde staat
    let factors: [Factor]
    let advice: Advice?

    /// Wat je het beste kunt doen voordat je koopt.
    enum Advice {
        case askPhoto       // goede deal maar geen foto: vraag er eerst een
        case checkPhoto     // er is een foto: bekijk die vóór je koopt
        case suspicious     // opvallend goedkoop: controleer extra goed

        var label: String {
            switch self {
            case .askPhoto: "Vraag eerst een foto"
            case .checkPhoto: "Check de foto"
            case .suspicious: "Verdacht goedkoop"
            }
        }
        var icon: String {
            switch self {
            case .askPhoto: "camera.badge.ellipsis"
            case .checkPhoto: "camera.viewfinder"
            case .suspicious: "exclamationmark.triangle.fill"
            }
        }
        var color: Color { self == .suspicious ? .orange : .blue }
    }
    /// Procent onder (+) of boven (−) de referentie.
    var discount: Double? { reference.map { 1 - total / $0 } }
}

@MainActor
enum DealEngine {
    /// Beoordeelt alle aanbiedingen onderling. De referentie is de mediaan van de totaalprijs in dezelfde staat.
    static func analyze(_ listings: [Listing], settings: AppSettings, tcgplayerEUR: Double?, trend: Double?) -> [UUID: DealScore] {
        let totals = Dictionary(uniqueKeysWithValues: listings.map { ($0.id, $0.price + settings.shipping(from: $0.country, price: $0.price)) })
        // Vergelijk alleen gelijke staat én variant (reverse, 1e editie, gesigneerd...); anders de gewone variant van die staat.
        var medians: [String: Double] = [:]
        for (key, items) in Dictionary(grouping: listings, by: \.variantKey) where items.count >= 4 {
            medians[key] = DealAnalyzer.percentile(items.compactMap { totals[$0.id] }.sorted(), 0.5)
        }
        for (cond, items) in Dictionary(grouping: listings.filter(\.isStandardVariant), by: \.condition) where items.count >= 4 {
            medians[cond] = DealAnalyzer.percentile(items.compactMap { totals[$0.id] }.sorted(), 0.5)
        }
        let overall = listings.count >= 4 ? DealAnalyzer.percentile(totals.values.sorted(), 0.5) : nil

        var out: [UUID: DealScore] = [:]
        for l in listings {
            let quote = settings.quote(from: l.country, price: l.price)
            let ship = quote?.price ?? 0
            let total = totals[l.id] ?? l.price
            let ref = medians[l.variantKey] ?? medians[l.condition] ?? overall
            var factors: [DealScore.Factor] = []
            var score = 50.0

            if let ref, ref > 0 {
                let ratio = total / ref
                score = min(100, max(0, 50 + (1 - ratio) * 125))
                let pct = Int((abs(1 - ratio) * 100).rounded())
                if pct >= 3 {
                    factors.append(.init(text: ratio < 1 ? "\(pct)% onder de mediaan van \(l.condition)-aanbiedingen" : "\(pct)% boven de mediaan van \(l.condition)-aanbiedingen", positive: ratio < 1))
                } else {
                    factors.append(.init(text: "Rond de mediaan van \(l.condition)-aanbiedingen", positive: nil))
                }
            } else {
                factors.append(.init(text: "Te weinig aanbiedingen om te vergelijken", positive: nil))
            }

            // Variant
            let names = ["reverse": "Reverse holo", "first": "1e editie", "signed": "Gesigneerd", "altered": "Altered (bewerkt)", "foil": "Foil"]
            for f in l.flags.sorted() {
                if f == "altered" { score -= 10; factors.append(.init(text: "Altered: kaart is bewerkt", positive: false)) }
                else { factors.append(.init(text: "\(names[f] ?? f): andere variant, prijs niet 1-op-1 vergelijkbaar", positive: nil)) }
            }
            if !l.comment.isEmpty { factors.append(.init(text: "Opmerking verkoper: \(l.comment)", positive: nil)) }

            // Verzending en herkomst
            let from = l.country.isEmpty ? "onbekend land" : l.country
            if let quote, ship > 0 {
                let kind = quote.tracked ? "aangetekend" : "brief"
                let source = quote.official ? "Cardmarket-tarief" : "schatting"
                factors.append(.init(text: "Uit \(from): \(euro(ship)) verzending (\(kind), \(source))", positive: l.country == settings.homeCountry ? true : nil))
            } else {
                factors.append(.init(text: "Uit \(from)", positive: nil))
            }
            if l.country == settings.homeCountry { score += 2 }

            // Verkoper
            switch l.sellerRating {
            case "outstanding": score += 6; factors.append(.init(text: "Verkoper: uitstekend", positive: true))
            case "verygood": score += 4; factors.append(.init(text: "Verkoper: zeer goed", positive: true))
            case "good": score += 1; factors.append(.init(text: "Verkoper: goed", positive: nil))
            case "average": score -= 3; factors.append(.init(text: "Verkoper: gemiddeld", positive: false))
            case "bad", "poor": score -= 8; factors.append(.init(text: "Verkoper: slecht", positive: false))
            default: break
            }
            if let n = l.sales {
                if n < 10 { score -= 6; factors.append(.init(text: "Nieuwe verkoper (\(n) verkopen)", positive: false)) }
                else if n >= 500 { score += 3; factors.append(.init(text: "Ervaren verkoper (\(n.formatted()) verkopen)", positive: true)) }
            }

            // Foto en levertijd
            if l.hasPhoto { score += 4; factors.append(.init(text: "Foto van de echte kaart", positive: true)) }
            else { factors.append(.init(text: "Geen foto van de kaart", positive: nil)) }
            if let d = l.deliveryDays ?? quote?.days {
                if d <= 3 { score += 2; factors.append(.init(text: "Snel geleverd (≈ \(d) dagen)", positive: true)) }
                else if d > 10 { score -= 3; factors.append(.init(text: "Lange levertijd (≈ \(d) dagen)", positive: false)) }
                else { factors.append(.init(text: "Levertijd ≈ \(d) dagen", positive: nil)) }
            }

            // Controle tegen een ander platform (alleen voor goede staten)
            if let tcg = tcgplayerEUR, tcg > 0, ["MT", "NM", "EX"].contains(l.condition) {
                let r = l.price / tcg
                if r < 0.9 { score += 4; factors.append(.init(text: "Onder TCGplayer (\(euro(tcg)))", positive: true)) }
                else if r > 1.15 { score -= 3; factors.append(.init(text: "Boven TCGplayer (\(euro(tcg)))", positive: false)) }
            }

            var value = Int(min(100, max(0, score)).rounded())

            // Een koopje zonder foto is onbewezen: de staat is dan niet te controleren.
            let discount = ref.map { 1 - total / $0 }
            if !l.hasPhoto, let d = discount, d >= 0.25, value > 79 {
                value = 79
                factors.append(.init(text: "Score begrensd: zonder foto kun je de staat niet controleren", positive: false))
            }
            var advice: DealScore.Advice?
            if let d = discount {
                let goodCondition = ["MT", "NM", "EX"].contains(l.condition)
                if d >= 0.35 { advice = .suspicious }
                else if !l.hasPhoto && d >= 0.12 && goodCondition { advice = .askPhoto }
                else if l.hasPhoto && d >= 0.12 { advice = .checkPhoto }
            }
            out[l.id] = DealScore(value: value, level: level(for: value), shipping: ship, total: total, reference: ref, factors: factors, advice: advice)
        }
        return out
    }

    static func level(for score: Int) -> Deal {
        switch score {
        case 80...: .great
        case 62..<80: .good
        case 42..<62: .fair
        default: .expensive
        }
    }
}

// MARK: - Verkoop-review

enum SaleVerdict {
    case tooHigh, fair, competitive, belowMarket, noData

    var label: String {
        switch self {
        case .tooHigh: "Te duur"
        case .fair: "Marktconform"
        case .competitive: "Scherp"
        case .belowMarket: "Onder de markt"
        case .noData: "Geen marktdata"
        }
    }
    var color: Color {
        switch self {
        case .tooHigh: .orange
        case .fair: .blue
        case .competitive: .green
        case .belowMarket: .purple
        case .noData: .secondary
        }
    }
}

struct SaleReview {
    let verdict: SaleVerdict
    let suggested: Double?     // advies: scherpe maar redelijke vraagprijs
    let fastSale: Double?      // prijs voor een snelle verkoop
    let net: Double?           // wat je overhoudt na commissie
    let text: String
}

@MainActor
enum SaleAdvisor {
    static func review(_ entry: CollectionEntry, market: MarketStore, settings: AppSettings) -> SaleReview {
        guard let ask = entry.askingPrice else {
            return SaleReview(verdict: .noData, suggested: nil, fastSale: nil, net: nil, text: "Geef een vraagprijs op om te laten beoordelen.")
        }
        let net = ask * (1 - settings.sellerFeePercent / 100)
        guard let s = market.stats(entry.productID, minCondition: entry.condition), s.count >= 8 else {
            return SaleReview(verdict: .noData, suggested: nil, fastSale: nil, net: net,
                              text: "Nog geen marktdata voor \(entry.condition.rawValue). Tik op Marktcheck om de aanbiedingen op te halen.")
        }
        let suggested = (s.p25 * 100).rounded() / 100
        let fast = max(0.01, ((s.min * 0.99) * 100).rounded() / 100)
        let verdict: SaleVerdict
        let text: String
        if ask > s.median * 1.10 {
            verdict = .tooHigh
            text = "Je vraagprijs ligt boven de mediaan (\(euro(s.median))) van \(entry.condition.rawValue)-aanbiedingen. Dat verkoopt traag."
        } else if ask >= s.p25 * 0.97 {
            verdict = .fair
            text = "Je zit tussen het goedkoopste kwart (\(euro(s.p25))) en de mediaan (\(euro(s.median))). Marktconform."
        } else if ask >= s.min * 0.95 {
            verdict = .competitive
            text = "Je zit in het goedkoopste kwart van de aanbiedingen. Dat verkoopt snel."
        } else {
            verdict = .belowMarket
            text = "Je zit onder het goedkoopste aanbod (\(euro(s.min))). Je laat waarschijnlijk geld liggen."
        }
        return SaleReview(verdict: verdict, suggested: suggested, fastSale: fast, net: net, text: text)
    }
}
