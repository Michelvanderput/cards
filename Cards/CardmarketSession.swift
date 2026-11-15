import Foundation
import Observation
import WebKit

/// Een ingelogde Cardmarket-sessie in een gewone webweergave. De app ziet nooit je wachtwoord:
/// je logt zelf in op de Cardmarket-pagina (iCloud-sleutelhanger kan invullen) en de cookies blijven bewaard
/// in de webopslag van de app, zodat je ingelogd blijft zolang Cardmarket de sessie toestaat.
@MainActor
@Observable
final class CardmarketSession: NSObject {
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private(set) var isLoggedIn = false
    private(set) var username: String?
    private(set) var needsCheck = false

    func openHome() {
        webView.load(URLRequest(url: URL(string: "https://www.cardmarket.com/en/Pokemon")!))
    }

    /// Controleert op de huidige pagina of je ingelogd bent.
    func refreshStatus() async {
        guard let json = try? await webView.evaluateJavaScript(Self.statusJS) as? String,
              let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(Status.self, from: data) else { return }
        needsCheck = s.challenge
        if !s.challenge {
            isLoggedIn = s.loggedIn
            username = s.loggedIn ? (s.user.isEmpty ? nil : s.user) : nil
        }
    }

    private struct Status: Decodable { let challenge, loggedIn: Bool; let user: String }

    private static let statusJS = """
    (function(){
      const challenge=!!document.querySelector('script[src*="challenge-platform"],#challenge-error-text,.cf-turnstile,#cf-chl-widget')
        || /just a moment|even geduld|un instant|einen moment|un momento/i.test(document.title);
      const out=document.querySelector('a[href*="Logout"],a[href*="User_Logout"]');
      const u=document.querySelector('a[href*="/Users/"]');
      const m=u?(u.getAttribute('href').match(/\\/Users\\/([^\\/?#]+)/)||[])[1]:'';
      return JSON.stringify({challenge:challenge,loggedIn:!!out,user:m||''});
    })()
    """
}

/// Eén regel uit je eigen Cardmarket-voorraad.
struct StockRow: Identifiable, Hashable {
    let id = UUID()
    let articleID: String
    let productID: Int?
    let name: String
    let condition: Condition?
    let language: String
    let price: Double?
    let quantity: Int
    let comment: String
}

/// Leest je eigen aanbod (Stock → Offers → Singles) uit Cardmarket. Experimenteel: de selectors komen uit
/// openbare projecten en zijn niet getest op elk account; de uitkomst toont daarom wat er herkend is.
@MainActor
@Observable
final class StockReader: NSObject {
    enum Status { case idle, loading, needsCheck, needsLogin, done, failed }
    let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private(set) var status: Status = .idle
    private(set) var rows: [StockRow] = []
    private(set) var pageTitle = ""
    private var task: Task<Void, Never>?

    func load() {
        task?.cancel()
        rows = []
        status = .loading
        webView.load(URLRequest(url: URL(string: "https://www.cardmarket.com/en/Pokemon/Stock/Offers/Singles")!))
        task = Task { await poll() }
    }

    func stop() { task?.cancel() }

    private func poll() async {
        var quiet = 0
        for _ in 0..<150 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(1))
            guard let json = try? await webView.evaluateJavaScript(Self.extractJS) as? String,
                  let data = json.data(using: .utf8),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { continue }
            pageTitle = page.title
            if page.challenge { status = .needsCheck; continue }
            if page.login { status = .needsLogin; continue }
            if !page.rows.isEmpty {
                for _ in 0..<6 {   // meer regels laden
                    let more = (try? await webView.evaluateJavaScript("(function(){const b=document.querySelector('#loadMoreButton');if(b&&!b.disabled&&b.offsetParent!==null){b.click();return true}return false})()")) as? Bool ?? false
                    if !more { break }
                    try? await Task.sleep(for: .seconds(1.5))
                }
                let final = (try? await webView.evaluateJavaScript(Self.extractJS) as? String)
                    .flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Page.self, from: $0) } ?? page
                rows = final.rows.map(Self.parse)
                status = .done
                return
            }
            status = .loading
            if !webView.isLoading { quiet += 1 }
            if quiet >= 10 { status = .done; return }   // ingelogd maar geen regels herkend
        }
        status = .failed
    }

    private struct Page: Decodable {
        struct Row: Decodable { let article, product, name, cond, lang, price, qty, comment: String }
        let title: String
        let challenge, login: Bool
        let rows: [Row]
    }

    private static func parse(_ r: Page.Row) -> StockRow {
        let cleaned = r.price.replacingOccurrences(of: "€", with: "").replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return StockRow(articleID: r.article, productID: Int(r.product), name: r.name, condition: Condition(rawValue: r.cond),
                        language: r.lang, price: Double(cleaned), quantity: Int(r.qty) ?? 1, comment: r.comment)
    }

    private static let extractJS = """
    (function(){
      const t=e=>e&&(e.getAttribute('data-bs-original-title')||e.getAttribute('aria-label')||e.getAttribute('title'));
      const first=(r,sels)=>{for(const s of sels){const e=r.querySelector(s);if(e&&e.textContent.trim())return e.textContent.trim();}return '';};
      const idProduct=r=>{const h=r.outerHTML;const m=h.match(/idProduct[=:"'\\s]+(\\d{3,})/i)||h.match(/data-id-product="(\\d+)"/i);return m?m[1]:'';};
      const challenge=!!document.querySelector('script[src*="challenge-platform"],#challenge-error-text,.cf-turnstile,#cf-chl-widget')
        || /just a moment|even geduld|un instant|einen moment|un momento/i.test(document.title);
      const rows=[...document.querySelectorAll('.article-row')].map(r=>({
        article:((r.outerHTML.match(/idArticle=(\\d+)/)||[])[1])||'',
        product:idProduct(r),
        name:first(r,['.col-seller a','a[href*="/Products/Singles/"]']),
        cond:(r.querySelector('.article-condition .badge')||{textContent:''}).textContent.trim(),
        lang:t(r.querySelector('.product-attributes .icon'))||'',
        price:(([...r.querySelectorAll('.price-container .color-primary')].find(x=>/\\d/.test(x.textContent)))||{textContent:''}).textContent.trim(),
        qty:first(r,['.item-count'])||'1',
        comment:first(r,['.product-comments .text-truncate','.product-comments'])
      }));
      return JSON.stringify({title:document.title,challenge:challenge,login:!!document.querySelector('input[type=password]'),rows:rows});
    })()
    """
}
