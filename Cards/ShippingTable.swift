import Foundation

/// Officiële Cardmarket-verzendtarieven naar Nederland, per land van herkomst.
/// Bron: de verzendkostenrekenaar op help.cardmarket.com/en/ShippingCosts (uitgelezen op de datum in het bestand).
/// Prijzen bevatten de verpakkingstoeslag. De tarieven kunnen veranderen; ververs het bestand dan met dezelfde rekenaar.
struct ShippingTable {
    struct Country: Decodable {
        let d: Int?           // gemiddelde levertijd (dagen)
        let u: [Double?]      // goedkoopste brief zonder tracking: tot 20 g (≤4 kaarten), 50 g (≤17), 100 g (≤40)
        let t: [Double?]      // goedkoopste aangetekend voor een waarde ≥ €25, ≥ €100, ≥ €500
    }
    private struct File: Decodable {
        let destination: String
        let fetched: String
        let source: String
        let countries: [String: Country]
    }

    let destination: String
    let fetched: String
    let countries: [String: Country]

    static let shared: ShippingTable? = {
        guard let url = Bundle.main.url(forResource: "shipping_nl", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return ShippingTable(destination: f.destination, fetched: f.fetched, countries: f.countries)
    }()

    struct Quote {
        let price: Double
        let days: Int?
        let tracked: Bool
    }

    /// Kosten voor `cards` kaarten met een totale waarde `value` uit `origin`. Nil als er geen tarief bekend is.
    func quote(from origin: String, value: Double, cards: Int = 1) -> Quote? {
        guard let c = countries[origin] else { return nil }
        // Boven €25 is aangetekend verplicht (Cardmarket).
        if value > 25 {
            let tracked = value <= 100 ? [c.t[1], c.t[2], c.t[0]] : [c.t[2], c.t[1], c.t[0]]
            if let p = tracked.compactMap({ $0 }).first { return Quote(price: p, days: c.d, tracked: true) }
            return nil
        }
        let tier = cards <= 4 ? 0 : cards <= 17 ? 1 : 2
        if let p = c.u[tier] ?? c.u[min(tier + 1, 2)] { return Quote(price: p, days: c.d, tracked: false) }
        // Geen brief beschikbaar: goedkoopste aangetekende optie.
        if let p = [c.t[0], c.t[1], c.t[2]].compactMap({ $0 }).first { return Quote(price: p, days: c.d, tracked: true) }
        return nil
    }
}
