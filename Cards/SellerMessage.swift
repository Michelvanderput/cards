import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Kant-en-klaar bericht om een verkoper om een foto te vragen, in de taal van het land van de verkoper.
/// De app verstuurt niets: je kopieert het bericht en stuurt het zelf via Cardmarket.
enum SellerMessage {
    enum Lang: String { case en, nl, de, fr, es, it }

    static func language(forCountry country: String) -> Lang {
        switch country {
        case "Netherlands": .nl
        case "Germany", "Austria", "Switzerland", "Liechtenstein": .de
        case "France": .fr
        case "Spain": .es
        case "Italy": .it
        default: .en
        }
    }

    static func make(card: String, condition: String, price: Double, lang: Lang) -> String {
        let p = price.formatted(.currency(code: "EUR").locale(Locale(identifier: lang == .en ? "en_IE" : "nl_NL")))
        switch lang {
        case .en: return "Hi, I'm interested in your \(card) (\(condition), \(p)). Before I buy, could you please send me a photo of the card (front and back, with the corners and edges clearly visible)? Thank you!"
        case .nl: return "Hoi, ik ben geïnteresseerd in je \(card) (\(condition), \(p)). Kun je me voordat ik koop een foto van de kaart sturen (voor- en achterkant, met de hoeken en randen goed zichtbaar)? Alvast bedankt!"
        case .de: return "Hallo, ich interessiere mich für deine \(card) (\(condition), \(p)). Könntest du mir vor dem Kauf bitte ein Foto der Karte schicken (Vorder- und Rückseite, Ecken und Ränder gut sichtbar)? Danke!"
        case .fr: return "Bonjour, votre \(card) (\(condition), \(p)) m'intéresse. Avant d'acheter, pourriez-vous m'envoyer une photo de la carte (recto et verso, avec les coins et les bords bien visibles) ? Merci !"
        case .es: return "Hola, me interesa tu \(card) (\(condition), \(p)). Antes de comprar, ¿podrías enviarme una foto de la carta (anverso y reverso, con las esquinas y los bordes bien visibles)? ¡Gracias!"
        case .it: return "Ciao, sono interessato alla tua \(card) (\(condition), \(p)). Prima di acquistare, potresti inviarmi una foto della carta (fronte e retro, con angoli e bordi ben visibili)? Grazie!"
        }
    }

    static func profileURL(seller: String) -> URL? {
        guard let name = seller.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://www.cardmarket.com/en/Pokemon/Users/\(name)")
    }

    static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
