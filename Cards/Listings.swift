import Foundation
import Observation
import SwiftUI
import WebKit

/// Eén aanbieding van een verkoper op Cardmarket.
struct Listing: Identifiable, Hashable {
    let id = UUID()
    let condition: String   // MT, NM, EX, GD, LP, PL, PO
    let language: String
    let price: Double
    let quantity: Int
    let seller: String
    let country: String
}

enum Condition: String, CaseIterable, Identifiable, Codable {
    case mt = "MT", nm = "NM", ex = "EX", gd = "GD", lp = "LP", pl = "PL", po = "PO"
    var id: String { rawValue }
    /// Waarde voor Cardmarkets `minCondition`-parameter (1 = Mint … 7 = Poor).
    var level: Int { Self.allCases.firstIndex(of: self)! + 1 }
    static func order(_ code: String) -> Int { Condition(rawValue: code)?.level ?? 99 }
    /// Keuzes voor filters en alerts.
    static let filterChoices: [Condition] = [.nm, .ex, .gd, .lp]
}

enum LanguageFilter: String, CaseIterable, Identifiable {
    case all, english
    var id: String { rawValue }
    var label: String { self == .all ? "Alle talen" : "Alleen Engels" }
    var queryItem: URLQueryItem? { self == .english ? URLQueryItem(name: "language", value: "1") : nil }
}

/// Laadt een Cardmarket-productpagina in een gewone webweergave (zodat Cloudflares controle
/// door jou zelf doorlopen kan worden) en leest daar de aanbiedingen uit.
/// De selectors zijn gebaseerd op de pagina-opbouw van nov 2026 en kunnen breken als Cardmarket die wijzigt.
@MainActor
@Observable
final class ListingsLoader: NSObject, WKNavigationDelegate {
    enum Status { case loading, needsCheck, done, failed }

    let webView: WKWebView
    private(set) var listings: [Listing] = []
    private(set) var status: Status = .loading
    private(set) var isPolling = false
    private var pollTask: Task<Void, Never>?
    private var pendingQuery: [URLQueryItem] = []
    private var generation = 0

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func load(productID: Int, minCondition: Condition?, language: LanguageFilter = .all) {
        pollTask?.cancel()
        status = .loading   // oude lijst blijft staan tot de nieuwe binnen is
        var comps = URLComponents(string: "https://www.cardmarket.com/en/Pokemon/Products")!
        comps.queryItems = [URLQueryItem(name: "idProduct", value: String(productID))]
        // Cardmarket stuurt door naar de echte pagina; de filters voegen we daar pas aan toe.
        pendingQuery = []
        if let minCondition { pendingQuery.append(URLQueryItem(name: "minCondition", value: String(minCondition.level))) }
        if let q = language.queryItem { pendingQuery.append(q) }
        webView.load(URLRequest(url: comps.url!))
        generation += 1
        let gen = generation
        isPolling = true
        pollTask = Task { await poll(gen) }
    }

    func stop() {
        pollTask?.cancel()
        isPolling = false
    }

    private func poll(_ gen: Int) async {
        defer { if gen == generation { isPolling = false } }
        var emptyStreak = 0
        for _ in 0..<120 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(1))
            if applyFiltersIfNeeded() { continue }   // eerst de gefilterde pagina laten laden
            guard let json = try? await webView.evaluateJavaScript(Self.extractJS) as? String,
                  let data = json.data(using: .utf8),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { continue }
            if !page.rows.isEmpty {
                // Laad een paar extra blokken aanbiedingen, zodat ook duurdere staten erbij komen.
                for _ in 0..<3 {
                    let clicked = (try? await webView.evaluateJavaScript(Self.loadMoreJS)) as? Bool ?? false
                    if !clicked { break }
                    try? await Task.sleep(for: .seconds(1.5))
                    if Task.isCancelled { return }
                }
                let final = (try? await webView.evaluateJavaScript(Self.extractJS) as? String)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(Page.self, from: $0) } ?? page
                listings = final.rows.compactMap(Self.parse).sorted { $0.price < $1.price }
                status = .done
                return
            }
            if page.title.contains("Just a moment") {
                status = .needsCheck
                emptyStreak = 0
            } else {
                status = .loading
                if !webView.isLoading { emptyStreak += 1 }
                // Pagina geladen maar geen aanbiedingen: waarschijnlijk geen resultaat voor dit filter.
                if emptyStreak >= 8 { listings = []; status = .done; return }
            }
        }
        status = .failed
    }

    /// Voegt de filters toe aan de echte kaartpagina-URL. Geeft true terug als er opnieuw geladen wordt.
    private func applyFiltersIfNeeded() -> Bool {
        guard !pendingQuery.isEmpty, let url = webView.url,
              url.host?.hasSuffix("cardmarket.com") == true, url.path.contains("/Singles/"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let names = Set(pendingQuery.map(\.name))
        var items = (comps.queryItems ?? []).filter { !names.contains($0.name) }
        items.append(contentsOf: pendingQuery)
        pendingQuery = []
        comps.queryItems = items
        guard let filtered = comps.url else { return false }
        webView.load(URLRequest(url: filtered))
        return true
    }

    private struct Page: Decodable {
        struct Row: Decodable { let cond, lang, price, qty, seller, loc: String }
        let title: String
        let rows: [Row]
    }

    private static func parse(_ r: Page.Row) -> Listing? {
        let cleaned = r.price.replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let price = Double(cleaned) else { return nil }
        return Listing(condition: r.cond, language: r.lang, price: price,
                       quantity: Int(r.qty) ?? 1, seller: r.seller, country: r.loc)
    }

    private static let loadMoreJS = """
    (function(){const b=document.querySelector('#loadMoreButton');
      if(b && !b.disabled && b.offsetParent!==null){b.click();return true;} return false;})()
    """

    private static let extractJS = """
    (function(){
      const t=e=>e&&(e.getAttribute('data-bs-original-title')||e.getAttribute('title'));
      const rows=[...document.querySelectorAll('.article-row')].map(r=>({
        cond:r.querySelector('.article-condition .badge')?.textContent.trim()||'',
        lang:t(r.querySelector('.product-attributes .icon'))||'',
        price:r.querySelector('.price-container .color-primary')?.textContent.trim()||'',
        qty:r.querySelector('.item-count')?.textContent.trim()||'1',
        seller:r.querySelector('.seller-name a')?.textContent.trim()||'',
        loc:(t(r.querySelector('.seller-name .icon'))||'').replace('Item location: ','')
      }));
      return JSON.stringify({title:document.title,rows:rows});
    })()
    """
}

// MARK: - WebView-wrapper (iOS + macOS)

#if os(iOS)
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
