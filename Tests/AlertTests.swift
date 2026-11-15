import XCTest
@testable import Cards

/// Verzamelt verstuurde meldingen in plaats van ze echt te sturen.
@MainActor
final class Recorder {
    var sent: [Notice] = []
    func notify(_ notice: Notice) async { sent.append(notice) }
}

@MainActor
class AlertTestCase: XCTestCase {
    var dir: URL!
    var recorder: Recorder!

    override func setUp() async throws {
        dir = URL.temporaryDirectory.appending(path: "cards-alert-\(UUID().uuidString)")
        recorder = Recorder()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func store() -> WatchStore {
        let s = WatchStore(storage: dir)
        let r = recorder!
        s.notifier = { notice in await r.notify(notice) }
        return s
    }

    func item(_ id: Int, trend: Double?, avg7: Double? = nil, avg: Double? = nil, name: String = "Kaart") -> CardItem {
        CardItem(id: id, name: name, expansionId: 1, metaID: nil,
                 normal: PriceSet(avg: avg, low: nil, trend: trend, avg1: nil, avg7: avg7, avg30: nil), holo: PriceSet())
    }

    func catalog(_ items: [CardItem]) -> CatalogStore {
        let c = CatalogStore()
        c.load(snapshot: Snapshot(fetchedAt: Date(), items: items), map: CardMap(sets: [1: "Set"]))
        return c
    }
}

final class TrendAlertTests: AlertTestCase {
    func testBelowAlertFiresOnceThenRearms() async {
        let w = store()
        w.add(item(1, trend: 20)); w.setAlert(1, target: 10, direction: .below, minCondition: nil)

        var n = await w.evaluate(catalog: catalog([item(1, trend: 20)]))        // te duur: niets
        XCTAssertEqual(n, 0); XCTAssertTrue(recorder.sent.isEmpty)

        n = await w.evaluate(catalog: catalog([item(1, trend: 9.5)]))           // onder de doelprijs: melding
        XCTAssertEqual(n, 1); XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertTrue(recorder.sent[0].body.contains("onder"))
        XCTAssertEqual(w.entry(1)?.alerted, true)

        n = await w.evaluate(catalog: catalog([item(1, trend: 9)]))             // nog steeds onder: geen tweede melding
        XCTAssertEqual(n, 0); XCTAssertEqual(recorder.sent.count, 1)

        _ = await w.evaluate(catalog: catalog([item(1, trend: 15)]))            // weer boven: alert wordt opnieuw actief
        XCTAssertEqual(w.entry(1)?.alerted, false)
        _ = await w.evaluate(catalog: catalog([item(1, trend: 8)]))             // opnieuw eronder: tweede melding
        XCTAssertEqual(recorder.sent.count, 2)
    }

    func testAboveAlert() async {
        let w = store()
        w.add(item(2, trend: 50)); w.setAlert(2, target: 100, direction: .above, minCondition: nil)
        _ = await w.evaluate(catalog: catalog([item(2, trend: 90)]))
        XCTAssertTrue(recorder.sent.isEmpty)
        _ = await w.evaluate(catalog: catalog([item(2, trend: 100)]))           // precies gelijk telt mee
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertTrue(recorder.sent[0].body.contains("boven"))
    }

    func testEntryWithoutTargetNeverNotifies() async {
        let w = store()
        w.add(item(3, trend: 1))
        let n = await w.evaluate(catalog: catalog([item(3, trend: 1)]))
        XCTAssertEqual(n, 0)
    }

    func testAlertAlreadyMetWhenCreatedFiresOnFirstEvaluation() async {
        let w = store()
        w.add(item(4, trend: 5)); w.setAlert(4, target: 10, direction: .below, minCondition: nil)
        _ = await w.evaluate(catalog: catalog([item(4, trend: 5)]))
        XCTAssertEqual(recorder.sent.count, 1, "een alert die al gehaald wordt moet meteen melden")
    }

    func testUsesSanePriceNotBogusTrend() async {
        // Echte prijsgids-afwijking: trend €0,02 maar 7-daags gemiddelde €25,55 (Chansey ex).
        let w = store()
        w.add(item(5, trend: 0.02)); w.setAlert(5, target: 10, direction: .below, minCondition: nil)
        _ = await w.evaluate(catalog: catalog([item(5, trend: 0.02, avg7: 25.55, avg: 47.59)]))
        XCTAssertTrue(recorder.sent.isEmpty, "een onzinnige trend mag geen 'onder je doelprijs'-melding geven")
    }

    func testUnknownCardsAreSkippedWithoutCrash() async {
        let w = store()
        w.add(item(6, trend: 5)); w.setAlert(6, target: 10, direction: .below, minCondition: nil)
        let n = await w.evaluate(catalog: catalog([]))                          // catalogus niet geladen
        XCTAssertEqual(n, 0)
    }

    func testSetAlertResetsState() async {
        let w = store()
        w.add(item(7, trend: 5)); w.setAlert(7, target: 10, direction: .below, minCondition: nil)
        _ = await w.evaluate(catalog: catalog([item(7, trend: 5)]))
        XCTAssertEqual(w.entry(7)?.alerted, true)
        w.setAlert(7, target: 3, direction: .below, minCondition: nil)          // doelprijs aangepast
        XCTAssertEqual(w.entry(7)?.alerted, false)
        _ = await w.evaluate(catalog: catalog([item(7, trend: 5)]))
        XCTAssertEqual(recorder.sent.count, 1, "met een lagere doelprijs is er niets nieuws")
    }

    func testConcurrentEvaluationsDoNotDoubleNotify() async {
        let w = store()
        w.add(item(8, trend: 5)); w.setAlert(8, target: 10, direction: .below, minCondition: nil)
        let r = recorder!
        w.notifier = { n in try? await Task.sleep(for: .milliseconds(80)); await r.notify(n) }
        let c = catalog([item(8, trend: 5)])
        async let a = w.evaluate(catalog: c)
        async let b = w.evaluate(catalog: c)
        _ = await (a, b)
        XCTAssertEqual(recorder.sent.count, 1)
    }

    func testDeletingWhileNotifyingDoesNotCrash() async {
        let w = store()
        for id in 10...12 { w.add(item(id, trend: 5)); w.setAlert(id, target: 10, direction: .below, minCondition: nil) }
        let r = recorder!
        w.notifier = { [weak w] n in await r.notify(n); w?.remove(ids: [11, 12]) }   // lijst verandert tijdens het melden
        let n = await w.evaluate(catalog: catalog((10...12).map { item($0, trend: 5) }))
        XCTAssertEqual(n, 1)
        XCTAssertEqual(w.entries.map(\.id), [10])
    }
}

final class ConditionAndDealAlertTests: AlertTestCase {
    func testConditionAlertFiresRearmsAndFiresAgain() async {
        let w = store()
        w.add(item(1, trend: 20)); w.setAlert(1, target: 10, direction: .below, minCondition: .nm)

        await w.applyConditionResult(id: 1, cheapest: 12)
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(w.entry(1)?.lastCheapest, 12)
        XCTAssertNotNil(w.entry(1)?.lastChecked)

        await w.applyConditionResult(id: 1, cheapest: 9)
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertTrue(recorder.sent[0].body.contains("NM+"))

        await w.applyConditionResult(id: 1, cheapest: 8)                         // blijft gehaald: geen tweede
        XCTAssertEqual(recorder.sent.count, 1)

        await w.applyConditionResult(id: 1, cheapest: 15)                        // weer te duur: opnieuw actief
        await w.applyConditionResult(id: 1, cheapest: 7)
        XCTAssertEqual(recorder.sent.count, 2)
    }

    func testConditionResultWithoutListingsKeepsState() async {
        let w = store()
        w.add(item(1, trend: 20)); w.setAlert(1, target: 10, direction: .below, minCondition: .ex)
        await w.applyConditionResult(id: 1, cheapest: nil)                       // geen aanbiedingen gevonden
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertNil(w.entry(1)?.lastCheapest)
    }

    func testConditionAlertsAreNotEvaluatedByTrendPass() async {
        let w = store()
        w.add(item(1, trend: 1)); w.setAlert(1, target: 10, direction: .below, minCondition: .nm)
        let n = await w.evaluate(catalog: catalog([item(1, trend: 1)]))          // trend telt niet voor een alert per staat
        XCTAssertEqual(n, 0)
    }

    func testConditionEntriesListsOnlyWhatNeedsListings() {
        let w = store()
        w.add(item(1, trend: 1)); w.setAlert(1, target: 10, direction: .below, minCondition: nil)       // trend-alert
        w.add(item(2, trend: 1)); w.setAlert(2, target: 10, direction: .below, minCondition: .nm)       // per staat
        w.add(item(3, trend: 1)); w.setAlert(3, target: nil, direction: .below, minCondition: nil, dealAlert: true)
        w.add(item(4, trend: 1))                                                                         // alleen volgen
        XCTAssertEqual(Set(w.conditionEntries.map(\.id)), [2, 3])
    }

    func testDealAlertNotifiesOncePerListing() async {
        let w = store()
        w.add(item(1, trend: 1)); w.setAlert(1, target: nil, direction: .below, minCondition: .ex, dealAlert: true)
        let t0 = Date()
        await w.applyDeal(id: 1, signature: "sellerA|10|NM", price: 10, body: "deal", now: t0)
        await w.applyDeal(id: 1, signature: "sellerA|10|NM", price: 10, body: "deal", now: t0)            // zelfde aanbieding: niet opnieuw
        await w.applyDeal(id: 1, signature: "sellerB|9.8|NM", price: 9.8, body: "bijna hetzelfde", now: t0 + 600)   // te weinig beter binnen 24 uur
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertTrue(recorder.sent[0].title.hasPrefix("Koopje"))
    }
}

final class WatchlistDeletionTests: AlertTestCase {
    func testRemoveSingleAndMultiplePersistAcrossReload() {
        let w = store()
        for id in 1...4 { w.add(item(id, trend: 1)) }
        w.remove(2)
        w.remove(ids: [3, 4])
        XCTAssertEqual(w.entries.map(\.id), [1])
        let reloaded = store()                                                   // nieuw exemplaar leest van schijf
        XCTAssertEqual(reloaded.entries.map(\.id), [1], "verwijderen moet bewaard blijven na herstarten")
    }

    func testRemoveUnknownIdIsHarmless() {
        let w = store()
        w.add(item(1, trend: 1))
        w.remove(999)
        XCTAssertEqual(w.entries.count, 1)
    }

    func testClearAlertKeepsTheCard() {
        let w = store()
        w.add(item(1, trend: 1)); w.setAlert(1, target: 5, direction: .below, minCondition: .nm, dealAlert: true)
        w.clearAlert(1)
        XCTAssertTrue(w.isWatching(1))
        XCTAssertNil(w.entry(1)?.target)
        XCTAssertNil(w.entry(1)?.minCondition)
        XCTAssertNil(w.entry(1)?.alertSummary)
        XCTAssertTrue(w.conditionEntries.isEmpty)
    }

    func testAddingTwiceDoesNotDuplicate() {
        let w = store()
        w.add(item(1, trend: 1)); w.add(item(1, trend: 1))
        XCTAssertEqual(w.entries.count, 1)
    }

    // MARK: iCloud: verwijderen moet verwijderd blijven

    private func data(_ ids: [Int], edit: [Int: Double] = [:]) throws -> Data {
        try JSONEncoder().encode(ids.map { id -> WatchEntry in var e = WatchEntry(id: id, name: "k\(id)"); e.target = edit[id]; return e })
    }
    private func ids(_ d: Data?) throws -> [Int] { try JSONDecoder().decode([WatchEntry].self, from: XCTUnwrap(d)).map(\.id).sorted() }

    func testLocalDeletionSurvivesConflictWithRemoteEdit() throws {
        // Basis: kaarten 1,2,3. Mac verwijdert 2. iPhone past ondertussen kaart 2 en 3 aan (bijv. lastChecked) en voegt 4 toe.
        let base = try data([1, 2, 3])
        let mac = try data([1, 3])
        let phone = try data([1, 2, 3, 4], edit: [2: 5, 3: 7])
        let merged = SyncMerge.merge(file: "watchlist.json", local: mac, remote: phone, base: base)
        XCTAssertEqual(try ids(merged), [1, 3, 4], "kaart 2 blijft verwijderd, kaart 3 blijft, nieuwe kaart 4 komt erbij")
        let entries = try JSONDecoder().decode([WatchEntry].self, from: XCTUnwrap(merged))
        XCTAssertEqual(entries.first { $0.id == 3 }?.target, 7, "wijziging van de iPhone blijft behouden")
    }

    func testRemoteDeletionSurvivesLocalEdit() throws {
        let base = try data([1, 2])
        let mac = try data([1, 2], edit: [2: 9])
        let phone = try data([1])
        XCTAssertEqual(try ids(SyncMerge.merge(file: "watchlist.json", local: mac, remote: phone, base: base)), [1])
    }

    func testBothSidesAddDifferentCardsKeepsBoth() throws {
        let base = try data([1])
        XCTAssertEqual(try ids(SyncMerge.merge(file: "watchlist.json", local: try data([1, 2]), remote: try data([1, 3]), base: base)), [1, 2, 3])
    }

    func testWithoutBaseFallsBackToUnion() throws {
        XCTAssertEqual(try ids(SyncMerge.merge(file: "watchlist.json", local: try data([1, 2]), remote: try data([2, 3]))), [1, 2, 3])
    }

    func testCollectionDeletionIsRespectedToo() throws {
        let a = CollectionEntry(productID: 1, name: "a"), b = CollectionEntry(productID: 2, name: "b")
        let enc = JSONEncoder()
        let base = try enc.encode([a, b]), local = try enc.encode([a]), remote = try enc.encode([a, b])
        let merged = try JSONDecoder().decode([CollectionEntry].self, from: XCTUnwrap(SyncMerge.merge(file: "collection.json", local: local, remote: remote, base: base)))
        XCTAssertEqual(merged.map(\.productID), [1])
    }
}

final class PriceInputTests: XCTestCase {
    func testParsesCommonTypingStyles() {
        let cases: [(String, Double?)] = [("12,50", 12.5), ("12.50", 12.5), ("12", 12), ("€ 12,5", 12.5), ("1.250,50", 1250.5),
                                          ("1,250.50", 1250.5), ("1.250", 1250), ("0,99", 0.99), ("0.99", 0.99), (" 7 ", 7), ("", nil), ("abc", nil)]
        for (text, expected) in cases { XCTAssertEqual(PriceInput.parse(text), expected, "'\(text)'") }
    }

    func testFormatRoundTrip() {
        XCTAssertEqual(PriceInput.format(12.5), "12,50")
        XCTAssertEqual(PriceInput.format(12), "12")
        XCTAssertEqual(PriceInput.format(nil), "")
        XCTAssertEqual(PriceInput.parse(PriceInput.format(7.25)), 7.25)
    }
}

final class AlertQualityTests: AlertTestCase {
    func testTitlesDropAttackNames() async {
        let w = store()
        w.add(item(1, trend: 5, name: "Aerodactyl ex [Primal Lock | Supersonic | Wing Attack]"))
        w.setAlert(1, target: 10, direction: .below, minCondition: nil)
        _ = await w.evaluate(catalog: catalog([item(1, trend: 5)]))
        XCTAssertEqual(recorder.sent.first?.title, "Aerodactyl ex")
        XCTAssertEqual("Altaria ex δ Delta Species [Extra Boost]".cleanCardName, "Altaria ex δ Delta Species")
        XCTAssertEqual("Professor Elm".cleanCardName, "Professor Elm")
    }

    func testNoticesReplaceInsteadOfStacking() async {
        // Dezelfde kaart en soort melding hebben dezelfde sleutel, zodat een nieuwe melding de oude vervangt.
        let w = store()
        w.add(item(7, trend: 5)); w.setAlert(7, target: 10, direction: .below, minCondition: nil)
        _ = await w.evaluate(catalog: catalog([item(7, trend: 5)]))
        _ = await w.evaluate(catalog: catalog([item(7, trend: 20)]))
        _ = await w.evaluate(catalog: catalog([item(7, trend: 4)]))
        XCTAssertEqual(recorder.sent.count, 2)
        XCTAssertEqual(Set(recorder.sent.map(\.key)), ["trend-7"], "beide meldingen delen één sleutel en vervangen elkaar")
        XCTAssertEqual(recorder.sent.first?.thread, "card-7")
    }

    func testDealThrottleWithin24Hours() {
        let w = store()
        w.add(item(1, trend: 1)); w.setAlert(1, target: nil, direction: .below, minCondition: .ex, dealAlert: true)
        let t0 = Date()
        XCTAssertNotNil(w.registerDeal(id: 1, signature: "a|10", price: 10, body: "x", now: t0))
        XCTAssertNil(w.registerDeal(id: 1, signature: "b|9.5", price: 9.5, body: "x", now: t0 + 3600), "5% beter binnen 24 uur: geen nieuwe melding")
        XCTAssertNotNil(w.registerDeal(id: 1, signature: "c|8", price: 8, body: "x", now: t0 + 7200), "20% beter: wel melden")
        XCTAssertNotNil(w.registerDeal(id: 1, signature: "d|8.5", price: 8.5, body: "x", now: t0 + 30 * 3600), "na 24 uur weer melden")
    }

    func testManyDealsAreSummarised() async {
        let w = store()
        for id in 1...5 { w.add(item(id, trend: 1, name: "Kaart \(id) ex [x]")); w.setAlert(id, target: nil, direction: .below, minCondition: .ex, dealAlert: true) }
        var notices: [Notice] = []
        for id in 1...5 { if let n = w.registerDeal(id: id, signature: "s\(id)", price: 5, body: "deal") { notices.append(n) } }
        await w.sendDeals(notices)
        XCTAssertEqual(recorder.sent.count, 1, "5 koopjes worden één samenvatting")
        XCTAssertEqual(recorder.sent[0].title, "5 koopjes gevonden")
        XCTAssertTrue(recorder.sent[0].body.contains("Kaart 1 ex"))
        XCTAssertTrue(recorder.sent[0].body.contains("en 2 meer"))
    }

    func testFewDealsAreSentIndividually() async {
        let w = store()
        for id in 1...2 { w.add(item(id, trend: 1)); w.setAlert(id, target: nil, direction: .below, minCondition: .ex, dealAlert: true) }
        let notices = (1...2).compactMap { w.registerDeal(id: $0, signature: "s\($0)", price: 5, body: "deal") }
        await w.sendDeals(notices)
        XCTAssertEqual(recorder.sent.count, 2)
        XCTAssertEqual(Set(recorder.sent.map(\.key)), ["deal-1", "deal-2"])
    }
}
