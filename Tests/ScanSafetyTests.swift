import XCTest
import WebKit
@testable import Cards

@MainActor
final class ScanSafetyTests: XCTestCase {
    private var savedRateLimit: RateLimitState!

    override func setUp() async throws {
        savedRateLimit = RateLimitState.shared
        RateLimitState.shared = RateLimitState(defaults: UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!)
        await RequestGate.shared.configure(minimum: 0, jitter: 0)
    }

    override func tearDown() async throws {
        ListingsLoader.testStartURL = nil
        RateLimitState.shared = savedRateLimit
        await RequestGate.shared.configure(minimum: 5, jitter: 3)
        UserDefaults.standard.removeObject(forKey: "hideGraded")
    }

    private func waitUntilDone(_ loader: ListingsLoader, timeout: TimeInterval = 15) async {
        let end = Date().addingTimeInterval(timeout)
        while loader.isPolling, Date() < end { try? await Task.sleep(for: .milliseconds(200)) }
    }

    private func realisticPage() -> String {
        PageFixtures.productPage(rows: [
            PageFixtures.row(seller: "Beyerinos", country: "Netherlands", price: "600,00 €", comment: "DM for more photo's!", photo: true, rating: "none", sales: 0),
            PageFixtures.row(seller: "GS-GameOn", country: "Italy", price: "3.000,00 €", comment: "[BGS 9.0]", pro: true, rating: "outstanding", sales: 29185),
            PageFixtures.row(seller: "pokeschins", country: "Netherlands", cond: "EX", price: "25,00 €", comment: "PSA6", pro: false, rating: "outstanding", sales: 77),
            PageFixtures.row(seller: "caspercor", country: "Denmark", price: "900,00 €", comment: "Light play", photo: true, pro: true),
        ])
    }

    // MARK: - Volledige uitleesketen op een nagebouwde echte pagina

    func testWholePipelineParsesRealisticRowsAndHidesGradedByDefault() async {
        UserDefaults.standard.removeObject(forKey: "hideGraded")
        ListingsLoader.testStartURL = { _ in PageFixtures.dataURL(self.realisticPage()) }
        let loader = ListingsLoader()
        loader.load(productID: 1, minCondition: nil, language: .all, loadMore: 0)
        await waitUntilDone(loader)
        XCTAssertEqual(loader.status, .done)
        // Gegradeerd (BGS 9.0 en PSA6) is verborgen; de professionele verkoper met het lege prijsicoon staat er wél tussen.
        XCTAssertEqual(loader.listings.map(\.seller), ["Beyerinos", "caspercor"])
        XCTAssertEqual(loader.hiddenGradedCount, 2)
        let pro = loader.listings.first { $0.seller == "caspercor" }
        XCTAssertEqual(pro?.price, 900, "de prijs van een professionele verkoper moet gelezen worden")
        XCTAssertEqual(pro?.isProfessional, true)
        XCTAssertEqual(pro?.country, "Denmark")
        XCTAssertEqual(pro?.language, "English")
        XCTAssertEqual(pro?.hasPhoto, true)
        let first = loader.listings[0]
        XCTAssertEqual(first.comment, "DM for more photo's!")
        XCTAssertEqual(first.sales, 0)
        XCTAssertEqual(first.deliveryDays, 6)
    }

    func testShowingGradedReturnsEverythingIncludingProPrices() async {
        UserDefaults.standard.set(false, forKey: "hideGraded")
        ListingsLoader.testStartURL = { _ in PageFixtures.dataURL(self.realisticPage()) }
        let loader = ListingsLoader()
        loader.load(productID: 1, minCondition: nil, language: .all, loadMore: 0)
        await waitUntilDone(loader)
        XCTAssertEqual(loader.listings.map(\.price), [25, 600, 900, 3000], "ook €3.000 van de professionele verkoper")
        XCTAssertEqual(loader.hiddenGradedCount, 0)
    }

    // MARK: - Blokkade door Cloudflare

    func testRateLimitPageStopsImmediatelyAndStartsCooldown() async {
        ListingsLoader.testStartURL = { _ in PageFixtures.dataURL(PageFixtures.rateLimited) }
        let loader = ListingsLoader()
        let t0 = Date()
        loader.load(productID: 1, minCondition: .ex, language: .english)
        await waitUntilDone(loader)
        XCTAssertEqual(loader.status, .rateLimited)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8, "een blokkade moet snel herkend worden, niet pas na 40 seconden")
        XCTAssertTrue(RateLimitState.shared.isCoolingDown)
        XCTAssertGreaterThan(RateLimitState.shared.remaining, 500)       // 10 minuten

        // Tijdens de wachttijd sturen we niets meer.
        var loaded = 0
        ListingsLoader.testStartURL = { _ in loaded += 1; return PageFixtures.dataURL(self.realisticPage()) }
        loader.load(productID: 2, minCondition: nil, language: .all)
        XCTAssertEqual(loader.status, .rateLimited)
        XCTAssertFalse(loader.isPolling)
        XCTAssertEqual(loaded, 0, "tijdens een blokkade mag er geen enkele lading starten")
    }

    func testCheckerStopsTheWholeScanOnRateLimit() async {
        var requested: [Int] = []
        ListingsLoader.testStartURL = { id in requested.append(id); return PageFixtures.dataURL(PageFixtures.rateLimited) }
        let checker = ConditionChecker()
        let m = MarketStore(storage: URL.temporaryDirectory.appending(path: "cards-scan-\(UUID().uuidString)"))
        let jobs = (1...10).map { (productID: $0, name: "k\($0)", condition: Optional(Condition.ex)) }
        let fetched = await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(requested.count, 1, "na de eerste blokkade stopt de scan; hij gaat niet door met de andere 9 kaarten")
        XCTAssertFalse(checker.isRunning)
        // Een nieuwe scan tijdens de wachttijd begint niet eens.
        let again = await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
        XCTAssertEqual(again, 0)
        XCTAssertEqual(requested.count, 1)
    }

    func testRecentlyScannedCardsAreNotRequestedAgain() async {
        var requested: [Int] = []
        ListingsLoader.testStartURL = { id in requested.append(id); return PageFixtures.dataURL(self.realisticPage()) }
        let checker = ConditionChecker()
        let m = MarketStore(storage: URL.temporaryDirectory.appending(path: "cards-scan-\(UUID().uuidString)"))
        let first = (1...3).map { (productID: $0, name: "k\($0)", condition: Optional(Condition.ex)) }
        let all = (1...5).map { (productID: $0, name: "k\($0)", condition: Optional(Condition.ex)) }
        _ = await checker.refreshMarket(jobs: first, language: .english, market: m, interactive: true)
        XCTAssertEqual(requested, [1, 2, 3])
        let fetched = await checker.refreshMarket(jobs: all, language: .english, market: m, interactive: true)   // "alle" na "eerste 3"
        XCTAssertEqual(fetched, 5)
        XCTAssertEqual(requested, [1, 2, 3, 4, 5], "de eerste drie zijn niet opnieuw opgevraagd")
    }

    // MARK: - Pure logica

    func testBlockPageDetectionOnRealCapturedText() {
        let captured = "Access denied | www.cardmarket.com used Cloudflare to restrict access | www.cardmarket.com | Cloudflare | https://www.cardmarket.com/en/Pokemon/Products | Error 1015 Ray ID: a5b128f8df549fe2 • 2026-11-15 20:56:00 UTC You are being rate limited What happened?"
        XCTAssertTrue(RateLimitState.isBlockPage(title: "Access denied | www.cardmarket.com used Cloudflare to restrict access", body: captured))
        XCTAssertTrue(RateLimitState.isBlockPage(title: "", body: "Error 1015 You are being rate limited"))
        XCTAssertFalse(RateLimitState.isBlockPage(title: "Mewtwo ex (101) - EX Ruby & Sapphire | Cardmarket", body: "Mewtwo ex Ruby Sapphire 101 Rare"))
        XCTAssertFalse(RateLimitState.isBlockPage(title: "Just a moment...", body: "Performing security verification"), "een gewone controle is geen blokkade")
    }

    func testCooldownGrowsButIsCapped() {
        XCTAssertEqual(RateLimitState.cooldown(strikes: 1), 600)
        XCTAssertEqual(RateLimitState.cooldown(strikes: 2), 1200)
        XCTAssertEqual(RateLimitState.cooldown(strikes: 3), 2400)
        XCTAssertEqual(RateLimitState.cooldown(strikes: 4), 3600)
        XCTAssertEqual(RateLimitState.cooldown(strikes: 9), 3600)
    }

    func testRepeatedBlocksExtendTheWaitAndOldOnesReset() {
        let s = RateLimitState(defaults: UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!)
        let t0 = Date()
        s.register(now: t0)
        XCTAssertEqual(s.until?.timeIntervalSince(t0) ?? 0, 600, accuracy: 1)
        s.register(now: t0 + 700)
        XCTAssertEqual(s.until?.timeIntervalSince(t0 + 700) ?? 0, 1200, accuracy: 1)
        s.register(now: t0 + 700 + 7 * 3600)          // ruim 6 uur later: weer een eerste blokkade
        XCTAssertEqual(s.until?.timeIntervalSince(t0 + 700 + 7 * 3600) ?? 0, 600, accuracy: 1)
    }

    func testPaceSlowsDownAfterBlocksAndRecovers() {
        let st = RateLimitState(defaults: UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!)
        XCTAssertEqual(st.paceFactor, 1)
        st.register(now: Date())
        XCTAssertEqual(st.paceFactor, 2)
        st.register(now: Date())
        XCTAssertEqual(st.paceFactor, 3)
        for _ in 0..<10 { st.register(now: Date()) }
        XCTAssertEqual(st.paceFactor, 5, "maximaal 5× trager")
        st.register(now: Date().addingTimeInterval(-7 * 3600))   // oude blokkade telt niet meer mee
    }

    func testLargeScansTakeRestBreaks() async {
        ListingsLoader.testStartURL = { _ in PageFixtures.dataURL(self.realisticPage()) }
        let checker = ConditionChecker()
        checker.breakEvery = 2
        checker.breakSeconds = 0.6
        let m = MarketStore(storage: URL.temporaryDirectory.appending(path: "cards-scan-\(UUID().uuidString)"))
        let jobs = (1...5).map { (productID: $0, name: "k\($0)", condition: Optional(Condition.ex)) }
        let t0 = Date()
        let fetched = await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
        XCTAssertEqual(fetched, 5)
        // 5 kaarten met een pauze na kaart 2 en 4: minstens twee pauzes van 0,6 s.
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 1.2)
        XCTAssertFalse(checker.isResting)
    }

    func testRequestGateSpacesLoadsOut() async {
        await RequestGate.shared.configure(minimum: 0.3, jitter: 0)
        let t0 = Date()
        for _ in 0..<3 { _ = await RequestGate.shared.waitTurn() }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.55, "drie ladingen met 0,3 s tussenruimte")
    }

    func testResolvedURLIsRememberedWithoutQuery() {
        let defaults = UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!
        ResolvedURLs.remember(URL(string: "https://www.cardmarket.com/en/Pokemon/Products/Singles/EX-Ruby-Sapphire/Mewtwo-ex-RS101?language=1&minCondition=2")!, for: 275749, defaults: defaults)
        XCTAssertEqual(ResolvedURLs.url(for: 275749, defaults: defaults)?.absoluteString,
                       "https://www.cardmarket.com/en/Pokemon/Products/Singles/EX-Ruby-Sapphire/Mewtwo-ex-RS101")
        ResolvedURLs.remember(URL(string: "https://www.cardmarket.com/en/Pokemon/Products?idProduct=1"), for: 1, defaults: defaults)   // geen kaartpagina
        XCTAssertNil(ResolvedURLs.url(for: 1, defaults: defaults))
        ResolvedURLs.remember(URL(string: "https://evil.example/Singles/x")!, for: 2, defaults: defaults)                              // andere site
        XCTAssertNil(ResolvedURLs.url(for: 2, defaults: defaults))
    }

    func testContentBlockingRulesAreValid() async throws {
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cards-light-test", encodedContentRuleList: ListingsLoader.lightRules)
        XCTAssertNotNil(list, "de regels voor het blokkeren van plaatjes en trackers moeten compileren")
    }
}
