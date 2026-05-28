import XCTest
@testable import FinGrowth

// Tests for P5-07 — Intent Router.
//
// Acceptance criteria checked here:
//   * 'What are my current positions?' → .localOnly
//   * 'What were NVDA earnings last quarter?' → .cloudAnalysis
//   * 'How does my portfolio compare to the S&P 500?' → .hybrid
//   * Classification completes within 1 second
//   * .hybrid + .cloudAnalysis are the only intents that produce a cloud
//     call; .localOnly never does. (The "no cloud call" half of the
//     acceptance is enforced in ResearchView and exercised at the view layer.)
final class IntentRouterTests: XCTestCase {

    // MARK: - Deterministic acceptance examples

    func testCurrentPositionsClassifiesAsLocalOnly() {
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "What are my current positions?"),
            .localOnly
        )
    }

    func testTickerEarningsClassifiesAsCloudAnalysis() {
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "What were NVDA earnings last quarter?"),
            .cloudAnalysis
        )
    }

    func testPortfolioVsBenchmarkClassifiesAsHybrid() {
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "How does my portfolio compare to the S&P 500?"),
            .hybrid
        )
    }

    // MARK: - Boundary cases that protect the privacy gate

    func testLocalOnlyForPersonalLookupWithoutMarketContext() {
        // "Show me my holdings" — first-person, no external benchmark → must
        // never reach the cloud.
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "Show me my holdings"),
            .localOnly
        )
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "What's my account balance?"),
            .localOnly
        )
    }

    func testCloudAnalysisForPureMarketQuery() {
        // No "my" → no portfolio context to leak; routes straight to cloud.
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "What is Apple's revenue trend?"),
            .cloudAnalysis
        )
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "How is the market doing today?"),
            .cloudAnalysis
        )
    }

    func testHybridForPersonalQueryAgainstBenchmark() {
        // The dangerous case: any first-person reference combined with an
        // external comparator must trigger the full privacy pipeline.
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "Is my portfolio outperforming the Nasdaq?"),
            .hybrid
        )
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "How do my returns compare against peers?"),
            .hybrid
        )
    }

    func testCurrentDoesNotTriggerMarketContext() {
        // Regression guard: "current" is a date qualifier, not a market
        // reference. Misreading it would push localOnly queries to the cloud.
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "What are my current holdings?"),
            .localOnly
        )
        XCTAssertEqual(
            IntentRouter.deterministicClassify(query: "Show my current allocation"),
            .localOnly
        )
    }

    // MARK: - Timing

    @MainActor
    func testClassificationCompletesWithinOneSecond() async {
        // The acceptance criterion is "Classification completes within 1
        // second." The deterministic path runs in microseconds; we wrap the
        // public async surface (which also takes the stub Gemma branch) and
        // assert a generous, real-clock bound so a regression that adds a
        // blocking model call here would fail.
        let service = GemmaService(backend: StubLlamaBackend(), downloader: nil)
        let router = IntentRouter(gemma: service)

        let start = ContinuousClock.now
        _ = await router.classify(query: "How does my portfolio compare to the S&P 500?")
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .seconds(1))
    }

    @MainActor
    func testGemmaServiceClassifyIntentExposesRouter() async {
        // The design-doc signature is `GemmaService.classifyIntent(query:) -> IntentType`.
        // Confirm it delegates to the same deterministic decision.
        let service = GemmaService(backend: StubLlamaBackend(), downloader: nil)
        let intent = await service.classifyIntent(query: "What are my current positions?")
        XCTAssertEqual(intent, .localOnly)
    }
}
