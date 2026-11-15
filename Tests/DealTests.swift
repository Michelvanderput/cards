import XCTest
@testable import Cards

@MainActor
final class DealTests: XCTestCase {
    private func settings() -> AppSettings {
        let suite = UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!
        let s = AppSettings(defaults: suite)
        s.homeCountry = "Netherlands"
        s.includeShipping = true
        return s
    }

    private func listing(_ price: Double, cond: String = "NM", country: String = "Netherlands",
                         rating: String = "good", sales: Int? = 100, flags: Set<String> = [], photo: Bool = false) -> Listing {
        Listing(condition: cond, language: "English", price: price, quantity: 1, seller: "s\(price)", country: country,
                sellerRating: rating, sales: sales, availableItems: nil, deliveryDays: 3, hasPhoto: photo, comment: "", flags: flags)
    }

    func testCheapestScoresHigherThanExpensive() {
        let items = (10...19).map { listing(Double($0), photo: true) }   // met foto: een groot verschil mag een koopje zijn
        let scores = DealEngine.analyze(items, settings: settings(), tcgplayerEUR: nil, trend: nil)
        let cheap = scores[items[0].id]!, dear = scores[items[9].id]!
        XCTAssertGreaterThan(cheap.value, dear.value)
        XCTAssertEqual(cheap.level, .great)
        XCTAssertTrue([Deal.fair, .expensive, .good].contains(dear.level))
    }

    func testOfficialShippingTableForNetherlands() {
        let s = settings()   // thuisland Nederland
        XCTAssertEqual(s.shipping(from: "Netherlands", price: 10), 1.70, accuracy: 0.001)       // brief tot 4 kaarten
        XCTAssertEqual(s.shipping(from: "Germany", price: 10), 1.55, accuracy: 0.001)
        XCTAssertEqual(s.shipping(from: "Germany", price: 60), 15.49, accuracy: 0.001)         // boven €25: aangetekend
        XCTAssertEqual(s.shipping(from: "Netherlands", price: 60), 6.20, accuracy: 0.001)
        XCTAssertEqual(s.shipping(from: "Germany", price: 20, cards: 10), 7.99, accuracy: 0.001) // 5–17 kaarten: tot 50 g
        let q = s.quote(from: "Finland", price: 12)
        XCTAssertEqual(q?.days, 9)
        XCTAssertEqual(q?.official, true)
        XCTAssertEqual(q?.tracked, false)
        XCTAssertEqual(s.quote(from: "Finland", price: 40)?.tracked, true)
    }

    func testFallbackEstimatesForOtherHomeCountry() {
        let s = settings()
        s.homeCountry = "Belgium"
        XCTAssertEqual(s.shipping(from: "Belgium", price: 10), s.shipDomestic)
        XCTAssertEqual(s.shipping(from: "Belgium", price: 25.01), s.shipDomesticTracked)
        XCTAssertEqual(s.shipping(from: "Germany", price: 10), s.shipEU)
        XCTAssertEqual(s.shipping(from: "Japan", price: 10), s.shipWorld)
        XCTAssertEqual(s.quote(from: "Germany", price: 10)?.official, false)
        s.includeShipping = false
        XCTAssertEqual(s.shipping(from: "Germany", price: 10), 0)
    }

    func testShippingTableLoadsAllCountries() {
        XCTAssertEqual(ShippingTable.shared?.countries.count, 34)
        XCTAssertEqual(ShippingTable.shared?.destination, "Netherlands")
    }

    func testForeignListingCostsMoreInTotal() {
        let items = [10.0, 10, 10, 10, 10].enumerated().map { i, p in listing(p, country: i == 0 ? "Japan" : "Netherlands") }
        let scores = DealEngine.analyze(items, settings: settings(), tcgplayerEUR: nil, trend: nil)
        XCTAssertGreaterThan(scores[items[0].id]!.total, scores[items[1].id]!.total)
        XCTAssertLessThan(scores[items[0].id]!.value, scores[items[1].id]!.value)
    }

    func testVariantsAreComparedSeparately() {
        // Gewone kaarten rond €10; gesigneerde rond €100. De gesigneerde mag niet als "duur" zakken.
        var items = (0..<6).map { listing(10 + Double($0) * 0.5) }
        let signed = (0..<5).map { listing(100 + Double($0), flags: ["signed"]) }
        items += signed
        let scores = DealEngine.analyze(items, settings: settings(), tcgplayerEUR: nil, trend: nil)
        let cheapSigned = scores[signed[0].id]!
        XCTAssertGreaterThanOrEqual(cheapSigned.value, 50, "gesigneerde kaart moet met gesigneerde kaarten vergeleken worden")
    }

    func testAlteredIsPenalised() {
        let base = (0..<5).map { _ in listing(10) }
        let altered = listing(10, flags: ["altered"])
        let scores = DealEngine.analyze(base + [altered], settings: settings(), tcgplayerEUR: nil, trend: nil)
        XCTAssertLessThan(scores[altered.id]!.value, scores[base[0].id]!.value)
    }

    func testTCGplayerCrossCheckRewardsLowPrice() {
        let items = (0..<5).map { listing(20 + Double($0)) }
        let without = DealEngine.analyze(items, settings: settings(), tcgplayerEUR: nil, trend: nil)[items[0].id]!.value
        let with = DealEngine.analyze(items, settings: settings(), tcgplayerEUR: 40, trend: nil)[items[0].id]!.value
        XCTAssertGreaterThan(with, without)
    }

    func testPercentile() {
        XCTAssertEqual(DealAnalyzer.percentile([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(DealAnalyzer.percentile([10, 20], 0.5), 15)
        XCTAssertEqual(DealAnalyzer.percentile([], 0.5), 0)
    }

    func testSaleAdvisorVerdicts() {
        let dir = URL.temporaryDirectory.appending(path: "cards-test-\(UUID().uuidString)")
        let market = MarketStore(storage: dir)
        let prices = (10...29).map { Double($0) }   // mediaan ≈ 19,5, p25 ≈ 14,75, min 10
        market.recordListings(id: 1, minCondition: .nm, listings: prices.map { listing($0) })
        let s = settings()

        func verdict(_ ask: Double?) -> SaleVerdict {
            SaleAdvisor.review(CollectionEntry(productID: 1, name: "x", condition: .nm, forSale: true, askingPrice: ask),
                               market: market, settings: s).verdict
        }
        XCTAssertEqual(verdict(30), .tooHigh)
        XCTAssertEqual(verdict(17), .fair)
        XCTAssertEqual(verdict(11), .competitive)
        XCTAssertEqual(verdict(5), .belowMarket)
        XCTAssertEqual(verdict(nil), .noData)

        let unknown = SaleAdvisor.review(CollectionEntry(productID: 2, name: "y", condition: .nm, forSale: true, askingPrice: 10),
                                         market: market, settings: s)
        XCTAssertEqual(unknown.verdict, .noData)
        XCTAssertEqual(unknown.net ?? 0, 9.5, accuracy: 0.001)   // 5% commissie
    }

    func testCollectionEntryDecodesOldFormat() throws {
        let old = #"{"id":"7B3F2B0A-1111-4222-8333-444455556666","productID":5,"name":"Old","condition":"EX","quantity":2,"note":"","added":0}"#
        let e = try JSONDecoder().decode(CollectionEntry.self, from: Data(old.utf8))
        XCTAssertEqual(e.productID, 5)
        XCTAssertFalse(e.forSale)
        XCTAssertNil(e.askingPrice)
    }

    func testBinderStoreLogic() {
        var b = Binder(name: "t", colorIndex: 0, columns: 3, rows: 3, pages: 2)
        XCTAssertEqual(b.slots.count, 18)
        b.slots[0] = 1
        XCTAssertEqual(b.filled, 1)
    }
}

@MainActor
final class PhotoAdviceTests: XCTestCase {
    private func settings() -> AppSettings {
        let s = AppSettings(defaults: UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!)
        s.includeShipping = false   // zuivere prijsvergelijking
        return s
    }
    private func listing(_ price: Double, photo: Bool, cond: String = "NM") -> Listing {
        Listing(condition: cond, language: "English", price: price, quantity: 1, seller: "s\(price)\(photo)", country: "Netherlands",
                sellerRating: "outstanding", sales: 1000, availableItems: nil, deliveryDays: 2, hasPhoto: photo, comment: "", flags: [])
    }

    func testBigDiscountWithoutPhotoIsCappedAndSuspicious() {
        let base = (0..<8).map { listing(20 + Double($0) * 0.1, photo: true) }
        let cheap = listing(11, photo: false)   // ruim 40% onder de markt
        let sc = DealEngine.analyze(base + [cheap], settings: settings(), tcgplayerEUR: nil, trend: nil)[cheap.id]!
        XCTAssertLessThanOrEqual(sc.value, 79)
        XCTAssertNotEqual(sc.level, .great)
        XCTAssertEqual(sc.advice, .suspicious)
    }

    func testBigDiscountWithPhotoCanBeKoopje() {
        let base = (0..<8).map { listing(20 + Double($0) * 0.1, photo: true) }
        let cheap = listing(11, photo: true)
        let sc = DealEngine.analyze(base + [cheap], settings: settings(), tcgplayerEUR: nil, trend: nil)[cheap.id]!
        XCTAssertGreaterThanOrEqual(sc.value, 80)
        XCTAssertEqual(sc.level, .great)
        XCTAssertEqual(sc.advice, .suspicious)   // ook mét foto: extra controle bij opvallend lage prijs
    }

    func testModerateDiscountAdvice() {
        let base = (0..<8).map { listing(20 + Double($0) * 0.1, photo: true) }
        let noPhoto = listing(17.5, photo: false)       // ≈ 17% onder de markt
        let withPhoto = listing(17.6, photo: true)
        let scores = DealEngine.analyze(base + [noPhoto, withPhoto], settings: settings(), tcgplayerEUR: nil, trend: nil)
        XCTAssertEqual(scores[noPhoto.id]?.advice, .askPhoto)
        XCTAssertEqual(scores[withPhoto.id]?.advice, .checkPhoto)
    }

    func testNoAdviceAtMarketPrice() {
        let base = (0..<8).map { listing(20 + Double($0) * 0.1, photo: false) }
        let scores = DealEngine.analyze(base, settings: settings(), tcgplayerEUR: nil, trend: nil)
        XCTAssertTrue(scores.values.allSatisfy { $0.advice == nil })
    }

    func testSellerMessageLanguagesAndNoSending() {
        XCTAssertEqual(SellerMessage.language(forCountry: "Germany"), .de)
        XCTAssertEqual(SellerMessage.language(forCountry: "Netherlands"), .nl)
        XCTAssertEqual(SellerMessage.language(forCountry: "Finland"), .en)
        let text = SellerMessage.make(card: "Charizard", condition: "NM", price: 12.5, lang: .de)
        XCTAssertTrue(text.contains("Charizard") && text.contains("NM") && text.contains("Foto"))
        XCTAssertEqual(SellerMessage.profileURL(seller: "Jan de Vries")?.absoluteString, "https://www.cardmarket.com/en/Pokemon/Users/Jan%20de%20Vries")
    }
}
