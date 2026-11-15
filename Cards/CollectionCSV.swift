import Foundation

/// Eén regel uit een CSV-bestand dat je wilt importeren.
struct CSVImportRow: Identifiable {
    let id = UUID()
    var name: String
    var productID: Int?
    var set: String?
    var condition: Condition
    var quantity: Int
    var paid: Double?
    var myPrice: Double?
    var asking: Double?
    var forSale: Bool
}

/// CSV lezen voor de collectie-import. Begrijpt de eigen export (puntkomma, Nederlandse kolomnamen)
/// en veelgebruikte Engelse kolomnamen uit andere apps en spreadsheets.
enum CollectionCSV {
    // MARK: - Parsen

    /// Splitst CSV-tekst in rijen en velden. Ondersteunt aanhalingstekens en de scheidingstekens ; , en tab.
    static func parse(_ text: String) -> [[String]] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" })
        // Het scheidingsteken dat het vaakst in de kopregel voorkomt.
        let candidates: [Character] = [";", ",", "\t"]
        let counts = candidates.map { c in firstLine.reduce(0) { $0 + ($1 == c ? 1 : 0) } }
        let delimiter: Character = counts.max().flatMap { m in m > 0 ? candidates[counts.firstIndex(of: m)!] : nil } ?? ";"
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = chars.next()
        while let c = pending {
            let next = chars.next()
            if inQuotes {
                if c == "\"" {
                    if next == "\"" { field.append("\""); pending = chars.next(); continue }
                    inQuotes = false
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                if c == "\r", next == "\n" { pending = chars.next() } else { pending = next }
                row.append(field); field = ""
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                continue
            } else { field.append(c) }
            pending = next
        }
        row.append(field)
        if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        return rows
    }

    static func number(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: "€", with: "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains(",") { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
        return Double(t)
    }

    private static let synonyms: [String: [String]] = [
        "name": ["naam", "name", "card", "card name", "kaart", "product", "productnaam"],
        "id": ["cardmarket_id", "cardmarket id", "idproduct", "id product", "product id", "id"],
        "set": ["set", "expansion", "expansie", "edition", "set name"],
        "condition": ["staat", "condition", "cond", "conditie"],
        "quantity": ["aantal", "quantity", "qty", "count", "amount"],
        "paid": ["betaald_per_kaart", "betaald", "paid", "purchase price", "cost", "kostprijs"],
        "mine": ["mijn_prijs", "my price", "value", "price", "waarde"],
        "ask": ["vraagprijs", "asking price", "ask", "asking"],
        "forSale": ["te_koop", "for sale", "forsale", "te koop"],
    ]

    /// Zet CSV-tekst om in importregels. Geeft een lege lijst als er geen kolom met een kaartnaam of id is.
    static func rows(from text: String) -> [CSVImportRow] {
        let table = parse(text)
        guard let header = table.first else { return [] }
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func col(_ key: String) -> Int? { names.firstIndex { synonyms[key]!.contains($0) } }
        let name = col("name"), id = col("id")
        guard name != nil || id != nil else { return [] }
        let cSet = col("set"), cCond = col("condition"), cQty = col("quantity"), cPaid = col("paid")
        let cMine = col("mine"), cAsk = col("ask"), cSale = col("forSale")

        func value(_ row: [String], _ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0].trimmingCharacters(in: .whitespaces) : nil } ?? "" }

        return table.dropFirst().compactMap { row in
            let n = value(row, name)
            let pid = Int(value(row, id))
            guard !n.isEmpty || pid != nil else { return nil }
            let cond = Condition(rawValue: value(row, cCond).uppercased()) ?? .nm
            let sale = ["ja", "yes", "true", "1", "y"].contains(value(row, cSale).lowercased())
            return CSVImportRow(name: n, productID: pid, set: value(row, cSet).isEmpty ? nil : value(row, cSet),
                                condition: cond, quantity: max(1, Int(value(row, cQty)) ?? 1),
                                paid: number(value(row, cPaid)), myPrice: number(value(row, cMine)),
                                asking: number(value(row, cAsk)), forSale: sale)
        }
    }

    // MARK: - Koppelen aan de catalogus

    struct MatchResult {
        var matched: [(row: CSVImportRow, item: CardItem)] = []
        var ambiguous: [CSVImportRow] = []
        var unmatched: [CSVImportRow] = []
    }

    static func key(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "é", with: "e").filter { $0.isLetter || $0.isNumber }
    }

    /// Koppelt via Cardmarket-id, anders op naam (en set, als die er is). Meerdere mogelijke kaarten = ambigu.
    @MainActor
    static func match(_ rows: [CSVImportRow], catalog: CatalogStore) -> MatchResult {
        var byBase: [String: [CardItem]] = [:]
        for item in catalog.items {
            let base = item.name.split(separator: "[", maxSplits: 1).first.map(String.init) ?? item.name
            byBase[key(base), default: []].append(item)
        }
        var result = MatchResult()
        for row in rows {
            if let pid = row.productID, let item = catalog.byID[pid] { result.matched.append((row, item)); continue }
            var candidates = byBase[key(row.name.split(separator: "[", maxSplits: 1).first.map(String.init) ?? row.name)] ?? []
            if candidates.isEmpty { result.unmatched.append(row); continue }
            if let set = row.set {
                let filtered = candidates.filter { catalog.map.sets[$0.expansionId].map(key) == key(set) }
                if !filtered.isEmpty { candidates = filtered }
            }
            if candidates.count == 1 { result.matched.append((row, candidates[0])) } else { result.ambiguous.append(row) }
        }
        return result
    }
}
