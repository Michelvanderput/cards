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

    /// Voegt twee versies van een bestand samen.
    /// - Met `base` (de laatst gesynchroniseerde versie) is dit een driewegs-samenvoeging: wat op één apparaat is
    ///   verwijderd blijft verwijderd (verwijderen wint van wijzigen), nieuwe items van beide kanten blijven, en bij
    ///   een wijziging aan één kant wint die kant.
    /// - Zonder `base` blijft alles uit beide versies behouden; bij hetzelfde id wint de versie van afstand.
    static func merge(file: String, local: Data, remote: Data, base: Data? = nil) -> Data? {
        let encoder = JSONEncoder()
        switch file {
        case "collection.json": return combine(CollectionEntry.self, local, remote, base, encoder) { $0.id }
        case "binders.json": return combine(Binder.self, local, remote, base, encoder) { $0.id }
        case "watchlist.json": return combine(WatchEntry.self, local, remote, base, encoder) { $0.id }
        case "ratelimit.json":
            // Pauzestand: de nieuwste versie wint.
            guard let l = try? RateLimitState.decoder.decode(RateLimitState.Snapshot.self, from: local),
                  let r = try? RateLimitState.decoder.decode(RateLimitState.Snapshot.self, from: remote) else { return nil }
            return RateLimitState.encode(l.updated > r.updated ? l : r)
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

    private static func combine<T: Codable & Equatable, ID: Hashable>(_ type: T.Type, _ local: Data, _ remote: Data, _ base: Data?,
                                                                   _ encoder: JSONEncoder, id: (T) -> ID) -> Data? {
        let decoder = JSONDecoder()
        guard let l = try? decoder.decode([T].self, from: local),
              let r = try? decoder.decode([T].self, from: remote) else { return nil }
        guard let base, let b = try? decoder.decode([T].self, from: base) else {
            let remoteIDs = Set(r.map(id))
            return try? encoder.encode(r + l.filter { !remoteIDs.contains(id($0)) })
        }
        let L = Dictionary(l.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        let R = Dictionary(r.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        let B = Dictionary(b.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        var out: [T] = []
        var seen = Set<ID>()
        for item in l + r {
            let key = id(item)
            guard seen.insert(key).inserted else { continue }
            let li = L[key], ri = R[key], bi = B[key]
            switch (li, ri, bi) {
            case let (l?, r?, b?):
                let localChanged = l != b, remoteChanged = r != b
                out.append(localChanged && !remoteChanged ? l : r)
            case (_, _, .some): break                    // aan één kant verwijderd: blijft verwijderd
            case let (l?, r?, nil): _ = l; out.append(r)   // aan beide kanten nieuw: versie van afstand
            case let (l?, nil, nil): out.append(l)
            case let (nil, r?, nil): out.append(r)
            default: break
            }
        }
        return try? encoder.encode(out)
    }
}
