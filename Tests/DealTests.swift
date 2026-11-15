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

final class LanguageFilterTests: XCTestCase {
    private func listing(_ lang: String) -> Listing {
        Listing(condition: "NM", language: lang, price: 10, quantity: 1, seller: lang, country: "Germany")
    }

    func testEnglishIsDefaultAndFiltersOthers() {
        XCTAssertEqual(LanguageFilter.defaultValue, .english)
        let all = ["English", "German", "Japanese", "", "French"].map(listing)
        let english = LanguageFilter.apply(.english, to: all)
        XCTAssertEqual(english.map(\.language), ["English"])
        XCTAssertEqual(LanguageFilter.apply(.all, to: all).count, 5)
    }
}

final class CSVTests: XCTestCase {
    func testParsesQuotesAndDelimiters() {
        let rows = CollectionCSV.parse("naam;aantal\n\"Pikachu; V\";2\n\"Say \"\"hi\"\"\";1\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["Pikachu; V", "2"])
        XCTAssertEqual(rows[2], ["Say \"hi\"", "1"])
        XCTAssertEqual(CollectionCSV.parse("a,b\n1,2")[1], ["1", "2"])   // komma gedetecteerd
    }

    func testNumberParsing() {
        XCTAssertEqual(CollectionCSV.number("12,50"), 12.5)
        XCTAssertEqual(CollectionCSV.number("1.234,56"), 1234.56)
        XCTAssertEqual(CollectionCSV.number("€ 3.5"), 3.5)
        XCTAssertNil(CollectionCSV.number(""))
    }

    func testReadsOwnExportFormat() {
        let text = "\u{FEFF}naam;cardmarket_id;set;staat;aantal;betaald_per_kaart;mijn_prijs;vraagprijs;te_koop;waarde_per_kaart\n" +
                   "Charizard;273699;Base Set;EX;2;10,00;15,50;20,00;ja;12,00\n"
        let rows = CollectionCSV.rows(from: text)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].productID, 273699)
        XCTAssertEqual(rows[0].condition, .ex)
        XCTAssertEqual(rows[0].quantity, 2)
        XCTAssertEqual(rows[0].paid, 10)
        XCTAssertEqual(rows[0].asking, 20)
        XCTAssertTrue(rows[0].forSale)
    }

    func testReadsEnglishHeadersAndDefaults() {
        let rows = CollectionCSV.rows(from: "Card Name,Qty,Condition\nPikachu,3,lp\nMew,,xx\n")
        XCTAssertEqual(rows.map(\.name), ["Pikachu", "Mew"])
        XCTAssertEqual(rows[0].condition, .lp)
        XCTAssertEqual(rows[1].condition, .nm)      // onbekende staat → NM
        XCTAssertEqual(rows[1].quantity, 1)         // leeg aantal → 1
    }

    func testRejectsFilesWithoutNameColumn() {
        XCTAssertTrue(CollectionCSV.rows(from: "foo;bar\n1;2").isEmpty)
    }

    func testKeyNormalisation() {
        XCTAssertEqual(CollectionCSV.key("Dragonite-GX"), CollectionCSV.key("Dragonite GX"))
        XCTAssertEqual(CollectionCSV.key("Pokémon"), CollectionCSV.key("pokemon"))
    }
}

final class SyncTests: XCTestCase {
    func testDecide() {
        typealias A = SyncMerge.Action
        XCTAssertEqual(SyncMerge.decide(localExists: false, remoteExists: false, localChanged: false, remoteChanged: false), A.none)
        XCTAssertEqual(SyncMerge.decide(localExists: true, remoteExists: false, localChanged: true, remoteChanged: false), A.push)
        XCTAssertEqual(SyncMerge.decide(localExists: false, remoteExists: true, localChanged: false, remoteChanged: true), A.pull)
        XCTAssertEqual(SyncMerge.decide(localExists: true, remoteExists: true, localChanged: true, remoteChanged: false), A.push)
        XCTAssertEqual(SyncMerge.decide(localExists: true, remoteExists: true, localChanged: false, remoteChanged: true), A.pull)
        XCTAssertEqual(SyncMerge.decide(localExists: true, remoteExists: true, localChanged: true, remoteChanged: true), A.merge)
        XCTAssertEqual(SyncMerge.decide(localExists: true, remoteExists: true, localChanged: false, remoteChanged: false), A.none)
    }

    func testMergeCollectionKeepsBothSides() throws {
        let shared = CollectionEntry(productID: 1, name: "Shared", quantity: 1)
        var remoteShared = shared; remoteShared.quantity = 5          // op afstand aangepast
        let localOnly = CollectionEntry(productID: 2, name: "Local")
        let remoteOnly = CollectionEntry(productID: 3, name: "Remote")
        let l = try JSONEncoder().encode([shared, localOnly])
        let r = try JSONEncoder().encode([remoteShared, remoteOnly])
        let merged = try JSONDecoder().decode([CollectionEntry].self, from: XCTUnwrap(SyncMerge.merge(file: "collection.json", local: l, remote: r)))
        XCTAssertEqual(Set(merged.map(\.productID)), [1, 2, 3])
        XCTAssertEqual(merged.first { $0.productID == 1 }?.quantity, 5)   // versie van afstand wint bij gelijk id
    }

    func testMergeHistoryUnionsPoints() throws {
        let d1 = Date(timeIntervalSince1970: 86400), d2 = Date(timeIntervalSince1970: 2 * 86400)
        let l = try JSONEncoder().encode([7: [PricePoint(date: d1, price: 1)], 8: [PricePoint(date: d1, price: 9)]])
        let r = try JSONEncoder().encode([7: [PricePoint(date: d2, price: 2)]])
        let merged = try JSONDecoder().decode([Int: [PricePoint]].self, from: XCTUnwrap(SyncMerge.merge(file: "history.json", local: l, remote: r)))
        XCTAssertEqual(merged[7]?.map(\.price), [1, 2])
        XCTAssertEqual(merged[8]?.count, 1)
    }

    func testMergeWatchlistAndUnknownFile() throws {
        let l = try JSONEncoder().encode([WatchEntry(id: 1, name: "a")])
        let r = try JSONEncoder().encode([WatchEntry(id: 2, name: "b")])
        let merged = try JSONDecoder().decode([WatchEntry].self, from: XCTUnwrap(SyncMerge.merge(file: "watchlist.json", local: l, remote: r)))
        XCTAssertEqual(Set(merged.map(\.id)), [1, 2])
        XCTAssertNil(SyncMerge.merge(file: "other.json", local: l, remote: r))
    }

    func testCorruptDataDoesNotCrashMerge() {
        XCTAssertNil(SyncMerge.merge(file: "collection.json", local: Data("x".utf8), remote: Data("y".utf8)))
    }
}

@MainActor
final class VariantGroupingTests: XCTestCase {
    private func item(_ id: Int, exp: Int, name: String = "Kaart") -> CardItem {
        CardItem(id: id, name: name, expansionId: exp, metaID: nil, normal: PriceSet(), holo: PriceSet())
    }

    private func catalog() -> CatalogStore {
        let items = [
            item(11, exp: 1), item(10, exp: 1),                 // zelfde fysieke kaart #4: reverse holo (11) en gewoon (10)
            item(12, exp: 1),                                   // andere kaart #173 (bv. alt art): blijft apart
            item(20, exp: 2),                                   // tweede deel van dezelfde Engelse set, zelfde kaart #4
            item(30, exp: 3),                                   // andere uitvoering (niet-hoofdset)
            item(50, exp: 5, name: "Gelijk"), item(51, exp: 5, name: "Gelijk"), item(52, exp: 5, name: "Uniek"),   // niet gekoppeld
        ]
        let map = CardMap(sets: [1: "Set A", 2: "Set A", 3: "Set A", 5: "Set C"],
                          images: [10: "en/x/seta/4", 11: "en/x/seta/4", 20: "en/x/seta/4", 12: "en/x/seta/173", 30: "en/x/seta/4"],
                          variants: [11: "Reverse holo"], main: [1, 2, 5], exact: [10, 11, 12, 20, 30])
        let store = CatalogStore()
        store.load(snapshot: Snapshot(fetchedAt: Date(), items: items), map: map)
        return store
    }

    func testMainSetPartsAreMergedAndOtherEditionsStaySeparate() {
        let c = catalog()
        let a = c.sets.first { $0.name == "Set A" }
        XCTAssertEqual(a?.expansionIDs, [1, 2])
        XCTAssertEqual(a?.count, 4)             // producten 11, 10, 12, 20
        XCTAssertEqual(a?.cardCount, 2)         // kaart #4 en kaart #173
        XCTAssertEqual(a?.isMain, true)
        let other = c.sets.first { $0.name == "Set A (andere uitvoering)" }
        XCTAssertEqual(other?.isMain, false)
        XCTAssertEqual(c.sets.count, 3)         // Set A, andere uitvoering, Set C
    }

    func testOnlyTheSamePhysicalCardIsGrouped() {
        let c = catalog()
        XCTAssertEqual(c.variants(of: c.byID[11]!).map(\.id), [10, 11, 20])
        XCTAssertEqual(c.variants(of: c.byID[12]!).map(\.id), [12])        // alt art blijft apart
        XCTAssertEqual(c.collapse([c.byID[11]!, c.byID[10]!, c.byID[12]!]).map(\.id), [10, 12])
    }

    func testRepresentativePrefersStandardVariantAndLabels() {
        let c = catalog()
        XCTAssertEqual(c.collapse([c.byID[11]!]).map(\.id), [10])
        XCTAssertEqual(c.variantLabel(for: c.byID[11]!), "Reverse holo")
        XCTAssertNil(c.variantLabel(for: c.byID[10]!))
        XCTAssertEqual(c.cardNumber(for: c.byID[12]!), "#173")
    }

    func testIdenticalUnlinkedProductsGetVersionLabelsAndAreNotHidden() {
        let c = catalog()
        XCTAssertEqual(c.variantLabel(for: c.byID[50]!), "V.1")
        XCTAssertEqual(c.variantLabel(for: c.byID[51]!), "V.2")
        XCTAssertNil(c.variantLabel(for: c.byID[52]!))
        XCTAssertEqual(c.collapse([c.byID[50]!, c.byID[51]!, c.byID[52]!]).count, 3)   // niets verborgen zonder zekerheid
    }

    func testOwnershipCountsAnyVariantOfSamePhysicalCard() {
        let c = catalog()
        XCTAssertTrue(c.isOwned(c.byID[10]!, ownedIDs: [11]))
        XCTAssertFalse(c.isOwned(c.byID[12]!, ownedIDs: [11]))
    }

    func testSetCardListsAreGrouped() {
        let c = catalog()
        let set = c.sets.first { $0.name == "Set A" }!
        XCTAssertEqual(c.cards(in: set, grouped: true).count, 2)
        XCTAssertEqual(c.cards(in: set, grouped: false).count, 4)
    }
}
