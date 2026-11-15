import Foundation

/// Nagebouwde Cardmarket-pagina's op basis van de echte structuur (gelezen op 15 nov 2026), voor tests zonder netwerk.
enum PageFixtures {
    static func dataURL(_ html: String) -> URL {
        URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    /// Eén aanbieding zoals Cardmarket die opbouwt. `pro` voegt het lege prijsicoon toe dat bij professionele verkopers staat.
    static func row(seller: String, country: String, cond: String = "NM", price: String, comment: String = "",
                    photo: Bool = false, pro: Bool = false, rating: String = "good", sales: Int = 20) -> String {
        """
        <div class="article-row">
          <div class="col-sellerProductInfo col"><div class="row g-0">
            <div class="col-seller"><span class="seller-info"><span class="seller-extended">
              <span><span class="fonticon-seller-rating-\(rating)" title="\(rating)"></span></span>
              <span class="badge sell-count" title="\(sales) Sales | 10 Available items">\(sales)</span>
              <span><span class="fonticon-calendar" title="&lt;div&gt;Estimated delivery time for \(seller) : 6 days&lt;/div&gt;"></span></span>
            </span>
            <span class="seller-name"><span class="icon" title="Item location: \(country)"></span>
              <span><a href="/en/Pokemon/Users/\(seller)">\(seller)</a></span>
              \(pro ? #"<span class="pro" title="Professional"></span>"# : "")
            </span></span></div>
            <div class="col-product"><div class="row g-0"><div class="product-attributes col">
              <a class="article-condition condition-\(cond.lowercased())" title="Near Mint"><span class="badge">\(cond)</span></a>
              <span class="icon me-2" title="English"></span>
              \(photo ? #"<span class="fonticon-camera" title="scan"></span>"# : "")
            </div>
            \(comment.isEmpty ? "" : #"<div class="product-comments"><span class="text-truncate">\#(comment)</span></div>"#)
            </div></div>
          </div></div>
          <div class="col-offer col-auto">
            <div class="price-container d-none d-md-flex">
              \(pro ? #"<span class="fonticon-check-circle extra-small color-primary me-2"></span>"# : "")
              <span class="color-primary small text-end text-nowrap fw-bold">\(price)</span>
            </div>
            <span class="item-count small text-end">1</span>
          </div>
        </div>
        """
    }

    static func productPage(rows: [String]) -> String {
        "<html><head><title>Mewtwo ex (101) - EX Ruby &amp; Sapphire | Cardmarket</title></head><body><div class=\"page-title-container\"><h1>Mewtwo ex</h1></div><div class=\"table-body\">\(rows.joined())</div></body></html>"
    }

    /// De blokkadepagina van Cloudflare zoals de app hem op 15 nov 2026 zag.
    static let rateLimited = "<html><head><title>Access denied | www.cardmarket.com used Cloudflare to restrict access</title></head><body><h1>Error 1015</h1><p>Ray ID: a5b128f8df549fe2 You are being rate limited</p><p>What happened? The owner of this website (www.cardmarket.com) has banned you temporarily from accessing this website.</p></body></html>"

    /// Een pagina die nooit "echt" wordt (geen aanbiedingen, geen productkenmerken): voor annuleringstests.
    static let neverReady = "<html><head><title>laden</title></head><body><p>bezig</p></body></html>"
}
