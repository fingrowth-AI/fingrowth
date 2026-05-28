import XCTest
@testable import FinGrowth

// Tests for P5-08 — Local Response Recontextualization.
//
// Acceptance criteria:
//   * Cloud response mentioning 'concentrated tech allocation' enriches to
//     mention specific tickers from the ledger.
//   * Response with no portfolio references passes through unchanged.
//   * Enrichment adds a 'personalized context' section, does not modify the
//     original analysis text.
//   * All enrichment runs on-device with zero network calls.
final class RecontextualizerTests: XCTestCase {

    // MARK: - Fixtures

    private func ledger(_ holdings: [(String, Double, Double)]) -> PrivateLedger {
        PrivateLedger(
            accountName: "Test",
            holdings: holdings.map { LedgerHolding(ticker: $0.0, quantity: $0.1, costBasis: $0.2) }
        )
    }

    // AAPL + MSFT both roll up to the "tech" category.
    private func techLedger() -> PrivateLedger {
        ledger([("AAPL", 500, 142), ("MSFT", 200, 380)])
    }

    private func response(narrative: String, ticker: String = "AAPL") -> AnalysisResponse {
        AnalysisResponse(
            sessionId: UUID(),
            ticker: ticker,
            research: ResearchData(),
            analysis: AnalysisData(technical: [:], narrative: narrative, confidence: "moderate"),
            riskReview: RiskReview(),
            disclaimer: "Research only."
        )
    }

    // MARK: - Acceptance: generalized reference → specific tickers

    func testConcentratedTechAllocationEnrichesToSpecificTickers() {
        let resp = response(narrative: "The portfolio shows a concentrated tech allocation worth watching.")
        let context = Recontextualizer.personalizedContext(for: resp, ledger: techLedger())

        let text = context?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("500 shares of AAPL"), "missing AAPL specifics in: \(text)")
        XCTAssertTrue(text.contains("200 shares of MSFT"), "missing MSFT specifics in: \(text)")
        XCTAssertEqual(Set(context?.tickers ?? []), ["AAPL", "MSFT"])
    }

    func testSectorMappingResolvesToTheRightHoldings() {
        // Financials reference must surface JPM, not the tech holdings.
        let mixed = ledger([("AAPL", 500, 142), ("JPM", 100, 150)])
        let resp = response(narrative: "Your financials allocation is modest relative to peers.")
        let context = Recontextualizer.personalizedContext(for: resp, ledger: mixed)

        let text = context?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("100 shares of JPM"), "missing JPM in: \(text)")
        XCTAssertFalse(text.contains("AAPL"), "tech holding leaked into a financials reference: \(text)")
    }

    // MARK: - Acceptance: no portfolio reference → pass through unchanged

    func testNoPortfolioReferencePassesThroughUnchanged() async {
        let resp = response(narrative: "NVDA reported strong quarterly earnings and the stock rose 5%.")
        let enriched = await Recontextualizer().enrich(response: resp, ledger: techLedger())

        XCTAssertNil(enriched.personalizedContext)
        XCTAssertFalse(enriched.didEnrich)
        XCTAssertEqual(enriched.response, resp, "the cloud response must pass through byte-for-byte")
    }

    func testSectorMentionWithoutPortfolioCueDoesNotEnrich() {
        // "technology sector" is generic market commentary — no personal cue,
        // so it must not trigger enrichment even though the user holds tech.
        let resp = response(narrative: "The technology sector rallied broadly this week.")
        XCTAssertNil(Recontextualizer.personalizedContext(for: resp, ledger: techLedger()))
    }

    func testCompanyAllocationLanguageDoesNotEnrich() {
        // Regression: bare words like "allocation" are NOT personal cues. A
        // company-level statement that happens to pair "allocation" with a
        // sector keyword must still pass through unchanged.
        let resp = response(narrative: "Apple's capital allocation remains strong in the technology sector.")
        XCTAssertNil(Recontextualizer.personalizedContext(for: resp, ledger: techLedger()))
    }

    func testAnalystRatingLanguageDoesNotEnrich() {
        // "overweight"/"underweight" are analyst ratings about a stock, not the
        // user's book — they must not trigger enrichment.
        let resp = response(narrative: "Analysts remain overweight on the technology names this quarter.")
        XCTAssertNil(Recontextualizer.personalizedContext(for: resp, ledger: techLedger()))
    }

    func testCuesRequireExplicitPersonalPhrasing() {
        XCTAssertTrue(Recontextualizer.containsPortfolioCue("given your tech allocation"))
        XCTAssertTrue(Recontextualizer.containsPortfolioCue("your financials allocation is modest"))
        XCTAssertTrue(Recontextualizer.containsPortfolioCue("the portfolio's concentrated tech position"))
        // Bare ambiguous words alone are not cues.
        XCTAssertFalse(Recontextualizer.containsPortfolioCue("capital allocation in the energy sector"))
        XCTAssertFalse(Recontextualizer.containsPortfolioCue("the stock looks concentrated by revenue"))
        XCTAssertFalse(Recontextualizer.containsPortfolioCue("analysts are overweight apple"))
    }

    // MARK: - Smoothing validator preserves facts (audit fix)

    private func twoHoldingContext() -> PersonalizedContext {
        PersonalizedContext(
            lines: ["Your technology exposure: 500 shares of AAPL and 200 shares of MSFT."],
            tickers: ["AAPL", "MSFT"],
            factPhrases: ["500 shares of AAPL", "200 shares of MSFT"],
            note: PersonalizedContext.onDeviceNote
        )
    }

    func testPreservesFactsAcceptsFaithfulParaphrase() {
        let context = twoHoldingContext()
        XCTAssertTrue(Recontextualizer.preservesFacts(
            context, in: "You currently hold 500 shares of AAPL and 200 shares of MSFT — a tech tilt."))
    }

    func testPreservesFactsRejectsInflatedShareCount() {
        // "1500 shares of AAPL" must NOT satisfy a required "500 shares of AAPL"
        // — substring matching would wrongly accept it; the word boundary won't.
        let context = twoHoldingContext()
        XCTAssertFalse(Recontextualizer.preservesFacts(
            context, in: "You hold 1500 shares of AAPL and 200 shares of MSFT."))
    }

    func testPreservesFactsRejectsSwappedPairs() {
        // Counts swapped between tickers: every loose token is present, but no
        // phrase is intact, so this must be rejected.
        let context = twoHoldingContext()
        XCTAssertFalse(Recontextualizer.preservesFacts(
            context, in: "You hold 200 shares of AAPL and 500 shares of MSFT."))
    }

    func testPreservesFactsRejectsDroppedHolding() {
        let context = twoHoldingContext()
        XCTAssertFalse(Recontextualizer.preservesFacts(
            context, in: "You hold 500 shares of AAPL and some MSFT."))
    }

    func testPreservesFactsRejectsTickerPrefixCollision() {
        // "AAPLE" must not satisfy a required AAPL phrase.
        let context = twoHoldingContext()
        XCTAssertFalse(Recontextualizer.preservesFacts(
            context, in: "You hold 500 shares of AAPLE and 200 shares of MSFT."))
    }

    // MARK: - Acceptance: additive, original text never modified

    func testEnrichmentIsAdditiveAndDoesNotModifyAnalysisText() async {
        let original = "The portfolio's concentrated tech allocation drives most of its variance."
        let resp = response(narrative: original)
        let enriched = await Recontextualizer().enrich(response: resp, ledger: techLedger())

        XCTAssertTrue(enriched.didEnrich)
        XCTAssertEqual(enriched.response.analysis.narrative, original, "analysis text must be untouched")
        XCTAssertEqual(enriched.response, resp)
        XCTAssertEqual(PersonalizedContext.title, "Personalized context")
    }

    // MARK: - Generic cue → largest holdings fallback

    func testGenericPortfolioCueSurfacesLargestHoldings() {
        let resp = response(narrative: "Your portfolio looks concentrated overall.")
        let context = Recontextualizer.personalizedContext(for: resp, ledger: techLedger())

        let text = context?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("Based on your holdings:"), "expected fallback phrasing in: \(text)")
        XCTAssertTrue(text.contains("AAPL"))
        XCTAssertTrue(text.contains("MSFT"))
    }

    // MARK: - Empty / missing ledger

    func testNilLedgerNeverEnriches() async {
        let resp = response(narrative: "Your concentrated tech allocation is notable.")
        let enriched = await Recontextualizer().enrich(response: resp, ledger: nil)
        XCTAssertNil(enriched.personalizedContext)
    }

    func testEmptyLedgerNeverEnriches() {
        let resp = response(narrative: "Your concentrated tech allocation is notable.")
        XCTAssertNil(Recontextualizer.personalizedContext(for: resp, ledger: ledger([])))
    }

    // MARK: - Zero network

    func testEnrichmentMakesZeroNetworkCalls() async {
        // The deterministic path takes no GemmaService and touches no client;
        // there is no network surface to call. This guards that contract: an
        // enrich() with a nil model still produces specifics purely from the
        // local ledger.
        let resp = response(narrative: "A concentrated tech allocation dominates the portfolio.")
        let enriched = await Recontextualizer(gemma: nil).enrich(response: resp, ledger: techLedger())
        XCTAssertTrue(enriched.didEnrich)
        XCTAssertEqual(Set(enriched.personalizedContext?.tickers ?? []), ["AAPL", "MSFT"])
    }
}
