import Foundation

/// Samenvatting van je collectie voor de widget. De app schrijft hem weg, de widget leest hem.
/// Wordt gedeeld via een App Group, dus er gaat niets buiten je apparaat.
struct WidgetSummary: Codable {
    var total: Double
    var cardCount: Int
    var moverName: String?
    var moverChange: Double?     // 0,12 = +12% t.o.v. het 7-daags gemiddelde
    var hideValues: Bool
    var updated: Date

    static let groupID = "group.nl.michelvanderput.cards"
    private static let key = "widgetSummary"

    static func load() -> WidgetSummary? {
        guard let data = UserDefaults(suiteName: groupID)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSummary.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults(suiteName: Self.groupID)?.set(data, forKey: Self.key) }
    }

    static let sample = WidgetSummary(total: 1234.5, cardCount: 87, moverName: "Charizard", moverChange: 0.08, hideValues: false, updated: .now)
}
