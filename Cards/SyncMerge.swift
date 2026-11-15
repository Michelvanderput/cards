import Foundation

/// Samenvoeglogica voor iCloud-synchronisatie (zuiver en testbaar).
enum SyncMerge {
    enum Action: Equatable { case none, push, pull, merge }

    /// Wat er moet gebeuren met één bestand, gegeven of het lokaal en/of op afstand veranderd is sinds de laatste sync.
    static func decide(localExists: Bool, remoteExists: Bool, localChanged: Bool, remoteChanged: Bool) -> Action {
        switch (localExists, remoteExists) {
        case (false, false): return .none
        case (true, false): return .push
        case (false, true): return .pull
        case (true, true):
            switch (localChanged, remoteChanged) {
            case (false, false): return .none
            case (true, false): return .push
            case (false, true): return .pull
            case (true, true): return .merge   // beide kanten gewijzigd: samenvoegen, niets verliezen
            }
        }
    }

    /// Voegt twee versies van een bestand samen: alles uit beide blijft behouden; bij hetzelfde id wint de versie van afstand.
    /// Verwijderingen op één apparaat kunnen bij zo'n conflict terugkomen; dat is bewust veiliger dan data kwijtraken.
    static func merge(file: String, local: Data, remote: Data) -> Data? {
        let encoder = JSONEncoder()
        switch file {
        case "collection.json": return union(CollectionEntry.self, local, remote, encoder) { $0.id }
        case "binders.json": return union(Binder.self, local, remote, encoder) { $0.id }
        case "watchlist.json": return union(WatchEntry.self, local, remote, encoder) { $0.id }
        case "history.json":
            guard let l = try? JSONDecoder().decode([Int: [PricePoint]].self, from: local),
                  let r = try? JSONDecoder().decode([Int: [PricePoint]].self, from: remote) else { return nil }
            var out = r
            for (id, points) in l {
                var byDate = Dictionary(uniqueKeysWithValues: (out[id] ?? []).map { ($0.date, $0) })
                for p in points where byDate[p.date] == nil { byDate[p.date] = p }
                out[id] = byDate.values.sorted { $0.date < $1.date }
            }
            return try? encoder.encode(out)
        default: return nil
        }
    }

    private static func union<T: Codable, ID: Hashable>(_ type: T.Type, _ local: Data, _ remote: Data,
                                                       _ encoder: JSONEncoder, id: (T) -> ID) -> Data? {
        guard let l = try? JSONDecoder().decode([T].self, from: local),
              let r = try? JSONDecoder().decode([T].self, from: remote) else { return nil }
        let remoteIDs = Set(r.map(id))
        return try? encoder.encode(r + l.filter { !remoteIDs.contains(id($0)) })
    }
}
