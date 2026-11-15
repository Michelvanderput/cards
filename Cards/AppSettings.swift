import Foundation
import Observation

/// Persoonlijke instellingen voor deals en verkopen. Bewaard in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Land waar jij woont (Engelse naam, zoals Cardmarket die toont).
    var homeCountry: String { didSet { defaults.set(homeCountry, forKey: "homeCountry") } }
    /// Schattingen voor andere landen dan Nederland (voor Nederland gelden de officiële tarieven).
    /// Brief (zonder tracking) en aangetekend/pakket. Boven €25 is aangetekend verzenden verplicht (Cardmarket).
    var shipDomestic: Double { didSet { defaults.set(shipDomestic, forKey: "shipDomestic") } }
    var shipDomesticTracked: Double { didSet { defaults.set(shipDomesticTracked, forKey: "shipDomesticTracked") } }
    var shipEU: Double { didSet { defaults.set(shipEU, forKey: "shipEU") } }
    var shipEUTracked: Double { didSet { defaults.set(shipEUTracked, forKey: "shipEUTracked") } }
    var shipWorld: Double { didSet { defaults.set(shipWorld, forKey: "shipWorld") } }
    var includeShipping: Bool { didSet { defaults.set(includeShipping, forKey: "includeShipping") } }
    /// Commissie die Cardmarket op een verkoop inhoudt (procent).
    var sellerFeePercent: Double { didSet { defaults.set(sellerFeePercent, forKey: "sellerFeePercent") } }
    /// Waarden verbergen (privacymodus).
    var hideValues: Bool { didSet { defaults.set(hideValues, forKey: "hideValues") } }

    static let trackedThreshold = 25.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        homeCountry = d.string(forKey: "homeCountry") ?? "Netherlands"
        shipDomestic = d.object(forKey: "shipDomestic") as? Double ?? 2.0
        shipDomesticTracked = d.object(forKey: "shipDomesticTracked") as? Double ?? 4.5
        shipEU = d.object(forKey: "shipEU") as? Double ?? 3.5
        shipEUTracked = d.object(forKey: "shipEUTracked") as? Double ?? 8.0
        shipWorld = d.object(forKey: "shipWorld") as? Double ?? 10.0
        includeShipping = d.object(forKey: "includeShipping") as? Bool ?? true
        sellerFeePercent = d.object(forKey: "sellerFeePercent") as? Double ?? 5.0
        hideValues = d.object(forKey: "hideValues") as? Bool ?? false
    }

    struct Quote { let price: Double; let days: Int?; let tracked: Bool; let official: Bool }

    /// Verzendkosten voor `cards` kaarten met een totale waarde `price`.
    func shipping(from country: String, price: Double, cards: Int = 1) -> Double {
        quote(from: country, price: price, cards: cards)?.price ?? 0
    }

    /// Voor Nederland (naar Nederland) de officiële Cardmarket-tarieven; anders de schattingen hierboven.
    func quote(from country: String, price: Double, cards: Int = 1) -> Quote? {
        guard includeShipping, !country.isEmpty else { return nil }
        if homeCountry == ShippingTable.shared?.destination,
           let q = ShippingTable.shared?.quote(from: country, value: price, cards: cards) {
            return Quote(price: q.price, days: q.days, tracked: q.tracked, official: true)
        }
        let tracked = price > Self.trackedThreshold
        if country == homeCountry {
            return Quote(price: tracked ? shipDomesticTracked : shipDomestic, days: nil, tracked: tracked, official: false)
        }
        if Self.euCountries.contains(country) && Self.euCountries.contains(homeCountry) {
            return Quote(price: tracked ? shipEUTracked : shipEU, days: nil, tracked: tracked, official: false)
        }
        return Quote(price: shipWorld, days: nil, tracked: true, official: false)
    }

    /// Bedrag tonen, of verborgen in privacymodus.
    func money(_ value: Double?) -> String {
        hideValues ? "€ ••••" : euro(value)
    }

    static let euCountries: Set<String> = [
        "Austria", "Belgium", "Bulgaria", "Croatia", "Cyprus", "Czech Republic", "Czechia", "Denmark", "Estonia",
        "Finland", "France", "Germany", "Greece", "Hungary", "Ireland", "Italy", "Latvia", "Lithuania",
        "Luxembourg", "Malta", "Netherlands", "Poland", "Portugal", "Romania", "Slovakia", "Slovenia", "Spain", "Sweden",
    ]

    /// Landen om uit te kiezen, alfabetisch (Engelse namen).
    static let countryChoices: [String] = [
        "Netherlands", "Belgium", "Germany", "France", "Italy", "Spain", "Portugal", "Austria", "Denmark", "Finland",
        "Sweden", "Poland", "Ireland", "Luxembourg", "United Kingdom", "Switzerland", "Norway",
    ].sorted()

    /// Vlag-emoji bij een Engelse landnaam (bijv. "Finland" → 🇫🇮).
    static func flag(_ country: String) -> String {
        guard let code = Self.regionCodes[country] else { return "🌍" }
        return code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }

    private static let regionCodes: [String: String] = {
        let en = Locale(identifier: "en")
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.subRegions.isEmpty {
            if let name = en.localizedString(forRegionCode: region.identifier) { map[name] = region.identifier }
        }
        map["Czech Republic"] = "CZ"; map["United Kingdom"] = "GB"; map["United States"] = "US"
        return map
    }()
}
