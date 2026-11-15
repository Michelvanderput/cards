import Foundation
import WidgetKit

/// Schrijft een korte samenvatting van je collectie naar de widget.
@MainActor
enum WidgetBridge {
    static func update(collection: CollectionStore, catalog: CatalogStore, settings: AppSettings) {
        let ids = Set(collection.entries.map(\.productID))
        let mover = ids.compactMap { id -> (CardItem, Double)? in
            guard let item = catalog.byID[id], let c = item.weekChange, c > 0 else { return nil }
            return (item, c)
        }.max { $0.1 < $1.1 }
        WidgetSummary(total: collection.totalValue(catalog: catalog), cardCount: collection.totalCards,
                      moverName: mover?.0.name.split(separator: "[").first.map { $0.trimmingCharacters(in: .whitespaces) },
                      moverChange: mover?.1, hideValues: settings.hideValues, updated: Date()).save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
