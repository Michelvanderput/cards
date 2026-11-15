import Foundation
import Observation

struct PricePoint: Codable, Identifiable, Hashable {
    let date: Date
    let price: Double
    var id: Date { date }
}

/// Houdt per kaart één prijs per dag bij (alleen voor kaarten die je bekijkt of volgt).
@MainActor
@Observable
final class HistoryStore {
    private(set) var points: [Int: [PricePoint]] = [:]
    /// Reeks voor de totale collectiewaarde.
    static let portfolioID = -1

    init() { load() }

    func record(id: Int, price: Double?, on date: Date = Date()) {
        guard let price else { return }
        let day = Calendar.current.startOfDay(for: date)
        var list = points[id] ?? []
        if let i = list.firstIndex(where: { $0.date == day }) {
            guard list[i].price != price else { return }
            list[i] = PricePoint(date: day, price: price)
        } else {
            list.append(PricePoint(date: day, price: price))
        }
        points[id] = list.sorted { $0.date < $1.date }
        save()
    }

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Cards", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Int: [PricePoint]].self, from: data) { points = decoded }
    }

    func reload() { load() }

    private func save() {
        if let data = try? JSONEncoder().encode(points) { try? data.write(to: fileURL, options: .atomic) }
        CloudSync.shared.localChanged("history.json")
    }
}
