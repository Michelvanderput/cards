import Foundation

/// Een verzameldoel: een vaste groep kaarten die je compleet wilt hebben.
struct Goal: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String

    static let exEra = Goal(
        id: "ex-era-pokemon-ex", title: "EX-era Pokémon-ex",
        subtitle: "Alle Pokémon-ex uit de 16 sets van 2003–2007 (Ruby & Sapphire t/m Power Keepers)",
        icon: "star.square.on.square")

    static let all = [exEra]
}

/// Verwijzing voor navigatie.
struct GoalRef: Hashable { let id: String }

enum GoalFilter {
    /// Een kaartnaam van een Pokémon-ex, zoals "Mewtwo ex" of "Altaria ex δ Delta Species" (zonder de aanvallen).
    static func isPokemonEx(_ name: String) -> Bool {
        let base = name.split(separator: "[", maxSplits: 1).first.map(String.init) ?? name
        return base.range(of: #"(^|\s)ex(\s|δ|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension CatalogStore {
    /// De kaarten van een doel, één per fysieke kaart, op volgorde van uitgave.
    func goalCards(_ goal: Goal) -> [CardItem] {
        switch goal.id {
        case Goal.exEra.id:
            // Engelse hoofdsets uit de TCGdex-serie "ex" (Ruby & Sapphire t/m Power Keepers).
            let era = Set(map.main.filter { map.setPaths[$0]?.hasPrefix("en/ex/") == true })
            let cards = items.filter { era.contains($0.expansionId) && GoalFilter.isPokemonEx($0.name) }
            return collapse(cards.sorted { ($0.expansionId, $0.id) < ($1.expansionId, $1.id) })
        default:
            return []
        }
    }
}
