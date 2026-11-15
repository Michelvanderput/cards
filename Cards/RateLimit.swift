import Foundation
import Observation

/// Houdt bij of Cardmarket (Cloudflare, "Error 1015") ons tijdelijk beperkt, en hoe lang we dan wachten.
/// Doorgaan tijdens een blokkade maakt het alleen erger, dus de app pauzeert.
@MainActor
@Observable
final class RateLimitState {
    static var shared = RateLimitState()

    private(set) var until: Date?
    private var strikes = 0
    private var lastStrike: Date?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        until = defaults.object(forKey: "rateLimit.until") as? Date
        strikes = defaults.integer(forKey: "rateLimit.strikes")
        lastStrike = defaults.object(forKey: "rateLimit.last") as? Date
    }

    /// Wachttijd na de n-de blokkade vlak achter elkaar: 10, 20, 40 minuten, maximaal 1 uur.
    nonisolated static func cooldown(strikes: Int) -> TimeInterval {
        min(600 * pow(2, Double(max(strikes - 1, 0))), 3600)
    }

    /// Hoeveel trager we laden na recente blokkades: 1× normaal, daarna 2×, 3×... (maximaal 5×) tot 6 uur na de laatste.
    var paceFactor: Double {
        guard let lastStrike, Date().timeIntervalSince(lastStrike) < 6 * 3600 else { return 1 }
        return Double(1 + min(strikes, 4))
    }

    var remaining: TimeInterval { max(until?.timeIntervalSinceNow ?? 0, 0) }
    var isCoolingDown: Bool { remaining > 0 }

    func register(now: Date = Date()) {
        // Een blokkade lang na de vorige telt als een nieuwe (teller weer op 1).
        if let lastStrike, now.timeIntervalSince(lastStrike) > 6 * 3600 { strikes = 0 }
        strikes += 1
        lastStrike = now
        until = now.addingTimeInterval(Self.cooldown(strikes: strikes))
        defaults.set(until, forKey: "rateLimit.until")
        defaults.set(strikes, forKey: "rateLimit.strikes")
        defaults.set(lastStrike, forKey: "rateLimit.last")
    }

    func clear() {
        until = nil
        defaults.removeObject(forKey: "rateLimit.until")
    }

    var message: String {
        guard let until, isCoolingDown else { return "" }
        return "Cardmarket beperkt even het aantal verzoeken (Cloudflare 1015). De app pauzeert tot \(until.formatted(date: .omitted, time: .shortened)) om het niet erger te maken."
    }

    /// Herkent de blokkadepagina's van Cloudflare (aan titel en begin van de tekst, taalonafhankelijk waar mogelijk).
    nonisolated static func isBlockPage(title: String, body: String) -> Bool {
        let text = (title + " " + body).lowercased()
        if text.contains("error 1015") || text.contains("you are being rate limited") || text.contains("rate limited") { return true }
        if text.contains("access denied"), text.contains("cloudflare") || text.contains("error 10") { return true }
        return false
    }
}

/// Zorgt voor een vaste pauze tussen pagina-ladingen van alle webweergaven samen (scan, kaartscherm, fotoscherm...).
/// Zo kunnen meerdere schermen tegelijk niet ongemerkt veel verzoeken sturen.
actor RequestGate {
    static let shared = RequestGate()
    /// Minimale tijd tussen twee ladingen en maximale extra willekeurige tijd (in seconden).
    var minimumSpacing: TimeInterval = 5
    var jitter: TimeInterval = 3
    private var nextAllowed = Date.distantPast

    func configure(minimum: TimeInterval, jitter: TimeInterval) {
        minimumSpacing = minimum
        self.jitter = jitter
    }

    /// Wacht tot deze lading aan de beurt is. Geeft false terug als de taak ondertussen is geannuleerd.
    func waitTurn() async -> Bool {
        let factor = await MainActor.run { RateLimitState.shared.paceFactor }   // na blokkades trager
        let now = Date()
        let start = max(now, nextAllowed)
        nextAllowed = start.addingTimeInterval((minimumSpacing + (jitter > 0 ? .random(in: 0...jitter) : 0)) * factor)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return false }
        }
        return !Task.isCancelled
    }
}

/// Onthoudt het uiteindelijke adres van een kaartpagina, zodat een volgende keer één lading genoeg is
/// (zonder de doorverwijzing van "idProduct" naar de echte pagina).
enum ResolvedURLs {
    private static let key = "resolvedProductURLs"

    static func url(for productID: Int, defaults: UserDefaults = .standard) -> URL? {
        (defaults.dictionary(forKey: key) as? [String: String])?[String(productID)].flatMap(URL.init(string:))
    }

    static func remember(_ url: URL?, for productID: Int, defaults: UserDefaults = .standard) {
        guard let url, url.host?.hasSuffix("cardmarket.com") == true, url.path.contains("/Singles/"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        comps.query = nil
        comps.fragment = nil
        guard let clean = comps.url else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[String(productID)] = clean.absoluteString
        defaults.set(all, forKey: key)
    }
}
