import SwiftUI

enum Deal {
    case great, good, fair, expensive

    var label: String {
        switch self {
        case .great: "Koopje"
        case .good: "Goede deal"
        case .fair: "Marktprijs"
        case .expensive: "Duur"
        }
    }
    var color: Color {
        switch self {
        case .great: .green
        case .good: .mint
        case .fair: .secondary
        case .expensive: .orange
        }
    }
}

@MainActor
enum DealAnalyzer {
    /// Beoordeelt een prijs ten opzichte van een referentieprijs (gelijke staat).
    static func rate(price: Double, reference: Double) -> Deal {
        let ratio = price / reference
        if ratio <= 0.85 { return .great }
        if ratio <= 0.95 { return .good }
        if ratio <= 1.05 { return .fair }
        return .expensive
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    /// Mediaan per staat (alleen als er minstens 4 aanbiedingen zijn).
    static func medians(of listings: [Listing]) -> [String: Double] {
        Dictionary(grouping: listings, by: \.condition).compactMapValues { items in
            items.count >= 4 ? percentile(items.map(\.price).sorted(), 0.5) : nil
        }
    }

    struct Suggestion {
        let price: Double
        let basis: String
    }

    /// Voorstel voor een goede alertprijs.
    /// - Met bekende aanbiedingen: de prijs waarmee je de goedkoopste 25% verslaat.
    /// - Anders: 10% onder het 30-daags gemiddelde (of de trend) van Cardmarket.
    static func suggestion(item: CardItem, minCondition: Condition?, market: MarketStore) -> Suggestion? {
        if let s = market.stats(item.id, minCondition: minCondition), s.count >= 8 {
            let label = minCondition.map { "\($0.rawValue) of beter" } ?? "alle staten"
            return Suggestion(price: (s.p25 * 100).rounded() / 100,
                              basis: "Goedkoopste kwart van \(s.count) aanbiedingen (\(label)). Mediaan \(euro(s.median)).")
        }
        let ref = item.normal.avg30 ?? item.holo.avg30 ?? item.mainPrice
        guard let ref else { return nil }
        let base = item.normal.avg30 != nil || item.holo.avg30 != nil ? "30-daags gemiddelde" : "trendprijs"
        var text = "10% onder het \(base) (\(euro(ref)), alle staten)."
        if minCondition != nil { text += " Bekijk eerst de aanbiedingen voor een nauwkeuriger voorstel per staat." }
        return Suggestion(price: ((ref * 0.9) * 100).rounded() / 100, basis: text)
    }
}
