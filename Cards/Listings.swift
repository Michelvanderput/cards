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

enum Condition: String, CaseIterable, Identifiable {
    case mt = "MT", nm = "NM", ex = "EX", gd = "GD", lp = "LP", pl = "PL", po = "PO"
    var id: String { rawValue }
    /// Waarde voor Cardmarkets `minCondition`-parameter (1 = Mint … 7 = Poor).
    var level: Int { Self.allCases.firstIndex(of: self)! + 1 }
    static func order(_ code: String) -> Int { Condition(rawValue: code)?.level ?? 99 }
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
    private var pollTask: Task<Void, Never>?
    private var pendingFilter: Condition?

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func load(productID: Int, minCondition: Condition?) {
        pollTask?.cancel()
        status = .loading   // oude lijst blijft staan tot de nieuwe binnen is
        var comps = URLComponents(string: "https://www.cardmarket.com/en/Pokemon/Products")!
        comps.queryItems = [URLQueryItem(name: "idProduct", value: String(productID))]
        pendingFilter = minCondition   // wordt na de doorverwijzing aan de echte pagina-URL toegevoegd
        webView.load(URLRequest(url: comps.url!))
        pollTask = Task { await poll() }
    }

    func stop() { pollTask?.cancel() }

    private func poll() async {
        // Wacht tot de aanbiedingen op de pagina staan (of tot jij de controle hebt doorlopen).
        var emptyStreak = 0
        for _ in 0..<120 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(1))
            if applyFilterIfNeeded() { continue }   // eerst de gefilterde pagina laten laden
            guard let json = try? await webView.evaluateJavaScript(Self.extractJS) as? String,
                  let data = json.data(using: .utf8),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { continue }
            if !page.rows.isEmpty {
                // Laad een paar extra blokken aanbiedingen, zodat ook duurdere staten (NM/EX) erbij komen.
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

    /// Cardmarket stuurt `Products?idProduct=…` door naar de echte kaartpagina; daar voegen we het filter aan toe.
    private func applyFilterIfNeeded() -> Bool {
        guard let cond = pendingFilter, let url = webView.url,
              url.host?.hasSuffix("cardmarket.com") == true, url.path.contains("/Singles/"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        pendingFilter = nil
        var items = (comps.queryItems ?? []).filter { $0.name != "minCondition" }
        items.append(URLQueryItem(name: "minCondition", value: String(cond.level)))
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
