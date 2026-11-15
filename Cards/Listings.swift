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
    var sellerRating: String = ""     // outstanding, verygood, good, ...
    var sales: Int? = nil             // aantal verkopen van de verkoper
    var availableItems: Int? = nil
    var deliveryDays: Int? = nil      // geschatte levertijd naar jou
    var hasPhoto: Bool = false        // verkoper heeft een foto van deze kaart geplaatst
    var comment: String = ""          // opmerking van de verkoper
    var flags: Set<String> = []       // reverse, first, signed, altered, foil
    var isProfessional: Bool = false  // professionele verkoper

    /// Gegradeerde kaarten (PSA/BGS/CGC...) staan op Cardmarket als gewone staat (meestal NM) met het cijfer in de opmerking.
    var isGraded: Bool { Self.looksGraded(comment) }

    static func looksGraded(_ text: String) -> Bool {
        text.range(of: #"\b(psa|bgs|cgc|sgc|ace|tag|ags|pca|gma|beckett)[\s\-:#]*\d|\b(graded|slab|slabbed)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Aanbiedingen zijn pas vergelijkbaar bij dezelfde staat én dezelfde variant.
    var variantKey: String { "\(condition)|" + flags.sorted().joined(separator: ",") }
    var isStandardVariant: Bool { flags.isEmpty }
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
    /// Je koopt alleen Engelse kaarten, dus dit is de standaard.
    static let defaultValue: LanguageFilter = .english

    /// Houdt alleen aanbiedingen in de gekozen taal over. Wordt altijd in de app zelf toegepast,
    /// ook als Cardmarket het taalfilter in de URL negeert. Aanbiedingen zonder herkende taal vallen bij Engels af.
    static func apply(_ filter: LanguageFilter, to listings: [Listing]) -> [Listing] {
        filter == .english ? listings.filter { $0.language == "English" } : listings
    }
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
    private var languageFilter: LanguageFilter = .defaultValue
    private var hideGraded = true
    private var maxLoadMore = 3
    /// Aantal verborgen gegradeerde aanbiedingen in de laatste lading.
    private(set) var hiddenGradedCount = 0
    private var generation = 0

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func load(productID: Int, minCondition: Condition?, language: LanguageFilter = .defaultValue, loadMore: Int = 3) {
        languageFilter = language
        maxLoadMore = loadMore
        hideGraded = Self.hideGradedSetting
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

    /// Markeert de rij van een verkoper op de geladen pagina en scrolt ernaartoe, zodat je de foto
    /// (camera-icoon) zelf kunt bekijken. Laadt zo nodig meer aanbiedingen. Geeft terug of de rij gevonden is.
    func highlight(seller: String, price: Double) async -> Bool {
        let js = Self.highlightJS(seller: seller, price: price)
        for _ in 0..<6 {
            if (try? await webView.evaluateJavaScript(js)) as? Bool == true { return true }
            let more = (try? await webView.evaluateJavaScript(Self.loadMoreJS)) as? Bool ?? false
            if !more { return false }
            try? await Task.sleep(for: .seconds(1.5))
        }
        return false
    }

    private static func highlightJS(seller: String, price: Double) -> String {
        let name = seller.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        (function(){
          const num=s=>parseFloat(s.replace(/\\./g,'').replace(/[^\\d,]/g,'').replace(',','.'));
          const row=[...document.querySelectorAll('.article-row')].find(r=>{
            const n=(r.querySelector('.seller-name a')||{}).textContent;
            const pe=[...r.querySelectorAll('.price-container .color-primary')].find(x=>/\\d/.test(x.textContent)); const p=(pe||{}).textContent||'';
            return n&&n.trim()==='\(name)'&&Math.abs(num(p)-\(price))<0.006;});
          if(!row) return false;
          row.scrollIntoView({block:'center'});
          row.style.outline='3px solid #5B4FEB'; row.style.background='rgba(91,79,235,0.10)';
          const cam=row.querySelector('.fonticon-camera');
          if(cam){cam.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));}
          return true;})()
        """
    }

    private func poll(_ gen: Int) async {
        defer { if gen == generation { isPolling = false } }
        var emptyStreak = 0
        var loadingTicks = 0      // seconden zonder resultaat en zonder beveiligingscontrole
        for _ in 0..<120 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(1))
            if applyFiltersIfNeeded() { continue }   // eerst de gefilterde pagina laten laden
            guard let json = try? await webView.evaluateJavaScript(Self.extractJS) as? String,
                  let data = json.data(using: .utf8),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { continue }
            if !page.rows.isEmpty {
                // Laad een paar extra blokken aanbiedingen, zodat ook duurdere staten erbij komen.
                for _ in 0..<maxLoadMore {
                    let clicked = (try? await webView.evaluateJavaScript(Self.loadMoreJS)) as? Bool ?? false
                    if !clicked { break }
                    try? await Task.sleep(for: .seconds(1.5))
                    if Task.isCancelled { return }
                }
                let final = (try? await webView.evaluateJavaScript(Self.extractJS) as? String)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(Page.self, from: $0) } ?? page
                let parsed = LanguageFilter.apply(languageFilter, to: final.rows.compactMap(Self.parse))
                hiddenGradedCount = hideGraded ? parsed.filter(\.isGraded).count : 0
                listings = (hideGraded ? parsed.filter { !$0.isGraded } : parsed).sorted { $0.price < $1.price }
                status = .done
                return
            }
            if page.challenge {
                status = .needsCheck
                emptyStreak = 0
            } else {
                status = .loading
                loadingTicks += 1
                if loadingTicks >= 40 { break }   // pagina laadt niet: sla deze kaart over in plaats van minutenlang te wachten
                // Alleen een echte productpagina zonder aanbiedingen telt als "geen resultaat voor dit filter".
                if page.real && !webView.isLoading { emptyStreak += 1 }
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
        struct Row: Decodable { let cond, lang, price, qty, seller, loc, rating, salesTitle, deliveryTitle, comment: String; let photo: Bool; let flags: [String]; let pro: Bool }
        let title: String
        let challenge: Bool   // Cloudflare-controle (taalonafhankelijk herkend)
        let real: Bool        // echte Cardmarket-productpagina
        let rows: [Row]
    }

    private static func parse(_ r: Page.Row) -> Listing? {
        let cleaned = r.price.replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let price = Double(cleaned) else { return nil }
        let numbers = r.salesTitle.replacingOccurrences(of: #"(?<=\d)[.,](?=\d{3})"#, with: "", options: .regularExpression)
            .matches(of: /\d+/).compactMap { Int($0.output) }
        let days = r.deliveryTitle.firstMatch(of: /:\s*(\d+)\s*day/).flatMap { Int($0.output.1) }
        return Listing(condition: r.cond, language: r.lang, price: price,
                       quantity: Int(r.qty) ?? 1, seller: r.seller, country: r.loc,
                       sellerRating: r.rating, sales: numbers.first, availableItems: numbers.dropFirst().first,
                       deliveryDays: days, hasPhoto: r.photo, comment: r.comment, flags: Set(r.flags), isProfessional: r.pro)
    }

    /// Standaard verbergen we gegradeerde kaarten: ze vertekenen de markt voor losse kaarten.
    static var hideGradedSetting: Bool { UserDefaults.standard.object(forKey: "hideGraded") as? Bool ?? true }

    private static let loadMoreJS = """
    (function(){const b=document.querySelector('#loadMoreButton');
      if(b && !b.disabled && b.offsetParent!==null){b.click();return true;} return false;})()
    """

    private static let extractJS = """
    (function(){
      const t=e=>e&&(e.getAttribute('data-bs-original-title')||e.getAttribute('title'));
      // Bij professionele verkopers staat voor de prijs een leeg icoon met dezelfde klasse: neem het element mét cijfers.
      const priceOf=r=>{const e=[...r.querySelectorAll('.price-container .color-primary')].find(x=>/\\d/.test(x.textContent));return e?e.textContent.trim():'';};
      const terms={reverse:['reverse'],first:['first edition','1st edition','erstauflage'],signed:['signed','signiert'],altered:['altered','verändert'],foil:['foil']};
      const flagsOf=r=>{const labels=[...r.querySelectorAll('.product-attributes [aria-label],.product-attributes [data-bs-original-title],.product-attributes [title]')].filter(e=>!e.closest('.product-comments')).map(e=>(e.getAttribute('aria-label')||e.getAttribute('data-bs-original-title')||e.getAttribute('title')||'').toLowerCase().replace(/<[^>]*>/g,''));
        return Object.keys(terms).filter(k=>labels.some(l=>terms[k].some(t=>l.includes(t))));};
      const rows=[...document.querySelectorAll('.article-row')].map(r=>({
        cond:r.querySelector('.article-condition .badge')?.textContent.trim()||'',
        lang:t(r.querySelector('.product-attributes .icon'))||'',
        price:priceOf(r),
        qty:r.querySelector('.item-count')?.textContent.trim()||'1',
        seller:r.querySelector('.seller-name a')?.textContent.trim()||'',
        loc:(t(r.querySelector('.seller-name .icon'))||'').replace('Item location: ',''),
        rating:((r.querySelector('[class*="fonticon-seller-rating-"]')?.className||'').match(/fonticon-seller-rating-([a-z]+)/)||[])[1]||'',
        salesTitle:t(r.querySelector('.sell-count'))||'',
        deliveryTitle:t(r.querySelector('.fonticon-calendar'))||'',
        photo:!!r.querySelector('.fonticon-camera'),
        pro:[...r.querySelectorAll('[data-bs-original-title],[title]')].some(e=>t(e)==='Professional'),
        comment:(r.querySelector('.product-comments .text-truncate')||r.querySelector('.product-comments'))?.textContent.trim().slice(0,200)||'',
        flags:flagsOf(r)
      }));
      const challenge=!!document.querySelector('script[src*="challenge-platform"],#challenge-error-text,.cf-turnstile,#cf-chl-widget,#challenge-form')
        || /just a moment|even geduld|un instant|einen moment|un momento/i.test(document.title);
      const real=!challenge && !!document.querySelector('.table-body,#tabContent-info,.page-title-container');
      return JSON.stringify({title:document.title,challenge:challenge,real:real,rows:rows});
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
