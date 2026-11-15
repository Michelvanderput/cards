import XCTest
@testable import Cards

@MainActor
final class CheckerTests: XCTestCase {
    private var savedRateLimit: RateLimitState!

    override func setUp() async throws {
        // Geen echt netwerk en geen echte pauzes; een eigen wachttijd-status zodat de echte app er niets van merkt.
        savedRateLimit = RateLimitState.shared
        RateLimitState.shared = RateLimitState(defaults: UserDefaults(suiteName: "cards-tests-\(UUID().uuidString)")!)
        await RequestGate.shared.configure(minimum: 0, jitter: 0)
        ListingsLoader.testStartURL = { _ in PageFixtures.dataURL(PageFixtures.neverReady) }
    }

    override func tearDown() async throws {
        ListingsLoader.testStartURL = nil
        RateLimitState.shared = savedRateLimit
        await RequestGate.shared.configure(minimum: 5, jitter: 3)
    }

    private func market() -> MarketStore { MarketStore(storage: URL.temporaryDirectory.appending(path: "cards-checker-\(UUID().uuidString)")) }
    private let jobs: [(productID: Int, name: String, condition: Condition?)] = [
        (275749, "Mewtwo ex", .ex), (276752, "Meganium ex", .ex), (275974, "Rayquaza ex", .ex),
    ]

    /// Regressietest voor het vastlopen: annuleren moet de zoektocht netjes stoppen en de hoofdthread vrijlaten.
    func testCancelStopsTheSearchWithoutFreezing() async {
        let checker = ConditionChecker()
        let m = market()
        let finished = expectation(description: "zoektocht gestopt")
        let task = Task { @MainActor in
            await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
            finished.fulfill()
        }
        try? await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(checker.isRunning, "de zoektocht moet bezig zijn")
        checker.cancel()
        await fulfillment(of: [finished], timeout: 8)
        XCTAssertFalse(checker.isRunning)
        XCTAssertNil(checker.current)
        task.cancel()
    }

    /// Het sluiten van het scherm annuleert de taak zelf (zoals SwiftUI doet): dat mag niet blijven doordraaien.
    func testCancellingTheTaskItselfDoesNotSpin() async {
        let checker = ConditionChecker()
        let m = market()
        let finished = expectation(description: "taak beëindigd")
        let task = Task { @MainActor in
            await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
            finished.fulfill()
        }
        try? await Task.sleep(for: .seconds(1.5))
        task.cancel()                                                     // precies wat het sluiten van een sheet doet
        await fulfillment(of: [finished], timeout: 8)
        XCTAssertFalse(checker.isRunning)
    }

    /// Een handmatige zoektocht neemt een lopende (automatische) controle over in plaats van te wachten of te botsen.
    func testInteractiveSearchPreemptsARunningJob() async {
        let checker = ConditionChecker()
        let m = market()
        let firstDone = expectation(description: "eerste taak overgenomen")
        let first = Task { @MainActor in
            await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
            firstDone.fulfill()
        }
        try? await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(checker.isRunning)
        let second = Task { @MainActor in
            await checker.refreshMarket(jobs: [jobs[1]], language: .english, market: m, interactive: true)
        }
        await fulfillment(of: [firstDone], timeout: 8)                    // de eerste is gestopt door de tweede
        try? await Task.sleep(for: .seconds(1.0))
        XCTAssertTrue(checker.isRunning, "de tweede taak is gestart")
        XCTAssertEqual(checker.total, 1)
        checker.cancel()
        _ = await second.value
        first.cancel()
        XCTAssertFalse(checker.isRunning)
    }

    func testBackgroundRunDoesNotInterruptAManualOne() async {
        let checker = ConditionChecker()
        let m = market()
        let done = expectation(description: "handmatige taak gestopt")
        let manual = Task { @MainActor in
            await checker.refreshMarket(jobs: jobs, language: .english, market: m, interactive: true)
            done.fulfill()
        }
        try? await Task.sleep(for: .seconds(1.2))
        let fetched = await checker.refreshMarket(jobs: [jobs[0]], language: .english, market: m, interactive: false)   // achtergrond
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(checker.total, jobs.count, "de handmatige taak liep gewoon door")
        checker.cancel()
        await fulfillment(of: [done], timeout: 8)
        manual.cancel()
    }

    func testAutomaticRoundIsLimitedAndOldestFirst() {
        let now = Date()
        func entry(_ id: Int, checked: TimeInterval?) -> WatchEntry {
            var e = WatchEntry(id: id, name: "k\(id)"); e.dealAlert = true
            e.lastChecked = checked.map { now.addingTimeInterval(-$0) }
            return e
        }
        let entries = [entry(1, checked: 100), entry(2, checked: nil), entry(3, checked: 9 * 3600), entry(4, checked: 5 * 3600), entry(5, checked: 4 * 3600)]
        // Minimaal 3 uur oud, hooguit 2, de langst niet-gecontroleerde eerst: 2 (nooit), 3 (9 uur).
        let due = ConditionChecker.selectDue(entries, minimumAge: 3 * 3600, maxEntries: 2, now: now)
        XCTAssertEqual(due.map(\.id), [2, 3])
        XCTAssertEqual(ConditionChecker.selectDue(entries, minimumAge: 0, maxEntries: nil, now: now).count, 5, "een handmatige ronde doet alles")
        XCTAssertEqual(ConditionChecker.selectDue(entries, minimumAge: 3 * 3600, maxEntries: nil, now: now).map(\.id).sorted(), [2, 3, 4, 5])
    }
}
