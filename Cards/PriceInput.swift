import SwiftUI

/// Leest een prijs zoals mensen hem typen: "12,50", "12.50", "€ 12", "1.250,50", "1,250.50".
enum PriceInput {
    static func parse(_ text: String) -> Double? {
        let t = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        guard t.contains(where: \.isNumber) else { return nil }
        let lastComma = t.lastIndex(of: ","), lastDot = t.lastIndex(of: ".")
        var normalized = t
        switch (lastComma, lastDot) {
        case let (c?, d?):
            // Beide aanwezig: het laatste teken is het decimaalteken, het andere is een duizendtal-scheiding.
            let decimal: Character = c > d ? "," : "."
            let thousands: Character = decimal == "," ? "." : ","
            normalized = t.replacingOccurrences(of: String(thousands), with: "").replacingOccurrences(of: String(decimal), with: ".")
        case let (c?, nil), let (nil, c?):
            let sep = t[c]
            let parts = t.split(separator: sep, omittingEmptySubsequences: false)
            // Meerdere keren hetzelfde teken, of precies 3 cijfers erna bij een punt ("1.250"), is een duizendtal-scheiding.
            let isThousands = parts.count > 2 || (sep == "." && parts.last?.count == 3 && parts.count == 2 && parts[0].count <= 3 && parts[0] != "0")
            normalized = isThousands ? t.replacingOccurrences(of: String(sep), with: "") : t.replacingOccurrences(of: String(sep), with: ".")
        default: break
        }
        return Double(normalized)
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        let s = String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
        return s.hasSuffix(",00") ? String(s.dropLast(3)) : s
    }
}

/// Invoerveld voor een bedrag. De waarde wordt bij elke toetsaanslag bijgewerkt (niet pas als het veld loslaat),
/// zodat een knop als "Bewaar" altijd de laatst getypte waarde ziet.
struct PriceField: View {
    let title: String
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        TextField(title, text: $text)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .onChange(of: text) { _, new in
                value = PriceInput.parse(new)
            }
            .onAppear { text = PriceInput.format(value) }
            .onChange(of: value) { _, new in
                // Alleen bijwerken als de waarde van buiten verandert (bijv. "Gebruik voorstel").
                if PriceInput.parse(text) != new { text = PriceInput.format(new) }
            }
    }
}
