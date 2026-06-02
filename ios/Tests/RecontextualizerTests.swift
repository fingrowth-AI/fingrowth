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

    private func response(
        narrative: String,
        ticker: String = "AAPL",
        technical: [String: JSONValue] = [:]
    ) -> AnalysisResponse {
        AnalysisResponse(
            sessionId: UUID(),
            ticker: ticker,
            research: ResearchData(),
            analysis: AnalysisData(technical: technical, narrative: narrative, confidence: "moderate"),
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
        // No portfolio cue AND the analyzed ticker (NVDA) isn't held → nothing to
        // enrich, so the cloud response passes through untouched.
        let resp = response(narrative: "NVDA reported strong quarterly earnings and the stock rose 5%.",
                            ticker: "NVDA")
        let enriched = await Recontextualizer().enrich(response: resp, ledger: techLedger())

        XCTAssertNil(enriched.personalizedContext)
        XCTAssertNil(enriched.positionInsight)
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

    // MARK: - V11-01: "What this means for you" (owns the analyzed ticker)

    func testPositionInsightWhenUserHoldsAnalyzedTicker() {
        // AC1: the result references the user's actual position in the ticker.
        let resp = response(narrative: "AAPL momentum looks elevated.", ticker: "AAPL")
        let insight = Recontextualizer.positionInsight(for: resp, ledger: techLedger())

        XCTAssertEqual(insight?.ticker, "AAPL")
        XCTAssertTrue(insight?.lines.first?.contains("500 shares of AAPL") ?? false)
        XCTAssertEqual(insight?.factPhrases, ["500 shares of AAPL"])
    }

    func testPositionInsightOmittedWhenTickerNotHeld() {
        // AC2: omitted gracefully when the user doesn't hold the analyzed ticker.
        let resp = response(narrative: "NVDA looks strong.", ticker: "NVDA")
        XCTAssertNil(Recontextualizer.positionInsight(for: resp, ledger: techLedger()))
    }

    func testPositionInsightNilForNilOrEmptyLedger() {
        let resp = response(narrative: "AAPL.", ticker: "AAPL")
        XCTAssertNil(Recontextualizer.positionInsight(for: resp, ledger: nil))
        XCTAssertNil(Recontextualizer.positionInsight(for: resp, ledger: ledger([])))
    }

    func testPositionInsightAggregatesLotsOfSameTicker() {
        let twoLots = ledger([("AAPL", 300, 100), ("AAPL", 200, 150)])  // 500 total
        let resp = response(narrative: "AAPL.", ticker: "AAPL")
        let insight = Recontextualizer.positionInsight(for: resp, ledger: twoLots)
        XCTAssertEqual(insight?.factPhrases, ["500 shares of AAPL"])
    }

    func testEnrichAttachesPositionInsightAdditivelyAndOnDevice() async {
        // AC3 (gemma=nil → on-device, zero network) + AC4 (cloud text unchanged).
        // The narrative has no portfolio cue, so the P5-08 mapping is nil — but
        // the position insight still fires because the user owns AAPL.
        let original = "AAPL reported earnings; the stock moved on the print."
        let resp = response(narrative: original, ticker: "AAPL")
        let enriched = await Recontextualizer(gemma: nil).enrich(response: resp, ledger: techLedger())

        XCTAssertNil(enriched.personalizedContext)  // no cue → no sector mapping
        XCTAssertNotNil(enriched.positionInsight)    // but owns the analyzed ticker
        XCTAssertTrue(enriched.didEnrich)            // P3: didEnrich reflects the insight
        XCTAssertTrue(enriched.positionInsight?.lines.first?.contains("500 shares of AAPL") ?? false)
        XCTAssertEqual(enriched.response.analysis.narrative, original)  // additive
        XCTAssertEqual(enriched.response, resp)
    }

    func testPositionInsightAggregatesAcrossMultipleLedgers() {
        // P2: a ticker held across multiple imported ledgers is summed, not
        // limited to the newest ledger.
        let a = ledger([("AAPL", 300, 100)])
        let b = ledger([("AAPL", 200, 150), ("MSFT", 50, 380)])
        let merged = a.holdings + b.holdings
        let resp = response(narrative: "AAPL.", ticker: "AAPL")
        let insight = Recontextualizer.positionInsight(for: resp, holdings: merged)
        XCTAssertEqual(insight?.factPhrases, ["500 shares of AAPL"])  // 300 + 200
    }

    func testGemmaSmoothingGuardRejectsAdvice() {
        // P1: the smoothing acceptance gate rejects directive/advice language,
        // even when the share-count fact is preserved.
        XCTAssertTrue(Recontextualizer.containsAdvice("You own 500 shares of AAPL, so you should sell."))
        XCTAssertTrue(Recontextualizer.containsAdvice("We recommend trimming your position."))
        XCTAssertTrue(Recontextualizer.containsAdvice("It's time to sell."))
        XCTAssertTrue(Recontextualizer.containsAdvice("Consider buying more."))
        // A faithful factual restatement is NOT advice.
        XCTAssertFalse(Recontextualizer.containsAdvice("You hold 500 shares of AAPL — a position you own."))
        XCTAssertFalse(Recontextualizer.containsAdvice(
            "Your technology exposure: 500 shares of AAPL and 200 shares of MSFT."))
    }

    func testEnrichOmitsPositionInsightWhenTickerNotHeld() async {
        let resp = response(narrative: "NVDA news.", ticker: "NVDA")
        let enriched = await Recontextualizer().enrich(response: resp, ledger: techLedger())
        XCTAssertNil(enriched.positionInsight)
    }

    func testPositionFactPhraseSurvivesParaphraseValidation() {
        XCTAssertTrue(Recontextualizer.factsPreserved(
            ["500 shares of AAPL"], in: "You own 500 shares of AAPL today."))
        // An inflated count must not satisfy the position fact.
        XCTAssertFalse(Recontextualizer.factsPreserved(
            ["500 shares of AAPL"], in: "You own 1500 shares of AAPL."))
    }

    // MARK: - V11-02: concentration and risk awareness

    // AAPL = 500*142 = 71,000 of a 147,000 book ≈ 48% → "concentrated" (>30%).
    private func overbought(_ ticker: String = "AAPL") -> AnalysisResponse {
        response(narrative: "\(ticker) momentum looks elevated.", ticker: ticker, technical: ["rsi": .double(75)])
    }

    func testPositionInsightStatesPercentageOfPortfolio() {
        // AC1: the result states position size as a percentage of the portfolio.
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: techLedger().holdings)
        XCTAssertNotNil(insight?.portfolioPercent)
        XCTAssertEqual(insight?.portfolioPercent ?? 0, 48.3, accuracy: 0.5)
        XCTAssertEqual(insight?.concentration, "concentrated")
        let text = insight?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("48% of your portfolio"), "missing percentage in: \(text)")
    }

    func testConcentratedPositionAmplifiesSignal() {
        // AC2: a concentrated stake makes the signal "carry more weight".
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: techLedger().holdings)
        let text = insight?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("overbought signal"), "signal not referenced: \(text)")
        XCTAssertTrue(text.contains("carries more weight"), "concentration didn't amplify: \(text)")
    }

    func testSmallPositionDampensSignal() {
        // AC2: the same overbought signal in a small position is framed as a
        // smaller factor — honest weighting in the other direction.
        // AAPL 1 share @ $100 vs a $99,900 NVDA stake → AAPL ≈ 0.1% (tiny).
        let book = ledger([("AAPL", 1, 100), ("NVDA", 100, 999)]).holdings
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: book)
        XCTAssertEqual(insight?.concentration, "tiny")
        let text = insight?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("is a smaller factor"), "small position didn't dampen: \(text)")
    }

    func testModeratePositionMakesNoAmplificationClaim() {
        // A ~10% position states the percentage but makes no honest claim that
        // the signal matters more or less — it just stands.
        // AAPL 100 @ $100 = 10,000 of a 100,000 book → 10% (moderate).
        let book = ledger([("AAPL", 100, 100), ("NVDA", 90, 1000)]).holdings
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: book)
        XCTAssertEqual(insight?.concentration, "moderate")
        let text = insight?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("10% of your portfolio"), "missing percentage in: \(text)")
        XCTAssertFalse(text.contains("carries more weight"))
        XCTAssertFalse(text.contains("is a smaller factor"))
    }

    func testPercentageOmittedWhenPortfolioValueUnknown() {
        // AC1 "when relevant": with no cost basis, the percentage can't be
        // computed honestly, so it's omitted — but the V11-01 holding line stays.
        let noBasis = ledger([("AAPL", 500, 0), ("MSFT", 200, 0)]).holdings
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: noBasis)
        XCTAssertNil(insight?.portfolioPercent)
        XCTAssertNil(insight?.concentration)
        XCTAssertEqual(insight?.lines.count, 1)
        XCTAssertTrue(insight?.lines.first?.contains("500 shares of AAPL") ?? false)
    }

    func testConcentrationFramingIsNeverAdvice() {
        // AC2: the framing must never read as a buy/sell/hold directive.
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: techLedger().holdings)
        for line in insight?.lines ?? [] {
            XCTAssertFalse(Recontextualizer.containsAdvice(line), "advice leaked into: \(line)")
        }
    }

    func testAdviceGuardRejectsRecommendationShapedPhrasing() {
        // P1: rating-shaped prose that preserves the fact but reads as advice
        // must be caught even though it uses no directive verb.
        XCTAssertTrue(Recontextualizer.containsAdvice("You own 500 shares of AAPL, a strong buy."))
        XCTAssertTrue(Recontextualizer.containsAdvice("You own 500 shares of AAPL — a buy."))
        XCTAssertTrue(Recontextualizer.containsAdvice("AAPL is rated a sell by the street."))
        XCTAssertTrue(Recontextualizer.containsAdvice("Analysts give it a buy rating."))
        XCTAssertTrue(Recontextualizer.containsAdvice("Hold this position for the long term."))
        XCTAssertTrue(Recontextualizer.containsAdvice("Hold onto your shares."))
        XCTAssertTrue(Recontextualizer.containsAdvice("The stock is rated outperform."))
        // The legitimate factual restatement must still NOT be flagged — the
        // V11-01 holding line and the V11-02 concentration framing are safe.
        XCTAssertFalse(Recontextualizer.containsAdvice(
            "You own 500 shares of AAPL, so this analysis is about a position you hold."))
        XCTAssertFalse(Recontextualizer.containsAdvice(
            "Because AAPL is such a large share of your portfolio, this overbought signal "
            + "carries more weight for you than it would in a smaller position."))
        XCTAssertFalse(Recontextualizer.containsAdvice("You hold 500 shares of AAPL — a position you own."))
    }

    func testPercentageOmittedWhenAnyHoldingLacksCostBasis() {
        // P3: a holding with missing/zero cost basis would silently understate
        // the denominator and overstate the analyzed position's share, so the
        // percentage is withheld entirely rather than asserting a misleading one.
        let partialBasis = ledger([("AAPL", 500, 142), ("MSFT", 200, 0)]).holdings
        let insight = Recontextualizer.positionInsight(for: overbought(), holdings: partialBasis)
        XCTAssertNil(insight?.portfolioPercent, "an incomplete-basis book must not assert a percentage")
        XCTAssertNil(insight?.concentration)
        XCTAssertEqual(insight?.lines.count, 1)  // V11-01 holding line only
        XCTAssertTrue(insight?.lines.first?.contains("500 shares of AAPL") ?? false)
    }

    func testNoSignalYieldsPercentageButNoWeighting() {
        // Neutral / absent indicators → state the percentage, but no signal to weigh.
        let resp = response(narrative: "AAPL traded sideways.", ticker: "AAPL", technical: ["rsi": .double(50)])
        let insight = Recontextualizer.positionInsight(for: resp, holdings: techLedger().holdings)
        let text = insight?.lines.joined(separator: " ") ?? ""
        XCTAssertTrue(text.contains("of your portfolio"))
        XCTAssertFalse(text.contains("signal"), "no signal should be weighed: \(text)")
    }

    func testSalientSignalPrefersRSIThenBollingerThenMACD() {
        XCTAssertEqual(Recontextualizer.salientSignal(in: ["rsi": .double(72)]), "overbought")
        XCTAssertEqual(Recontextualizer.salientSignal(in: ["rsi": .int(25)]), "oversold")
        XCTAssertEqual(Recontextualizer.salientSignal(in: [
            "latest_close": .double(110),
            "bollinger": .object(["upper": .double(100), "lower": .double(80)]),
        ]), "overextended")
        XCTAssertEqual(Recontextualizer.salientSignal(in: [
            "macd": .object(["histogram": .double(1.2)]),
        ]), "bullish")
        XCTAssertNil(Recontextualizer.salientSignal(in: ["rsi": .double(50)]))
        XCTAssertNil(Recontextualizer.salientSignal(in: [:]))
    }

    func testFormatPercentRoundsAndFloorsSubOnePercent() {
        XCTAssertEqual(Recontextualizer.formatPercent(48.3), "48%")
        XCTAssertEqual(Recontextualizer.formatPercent(0.4), "less than 1%")
        XCTAssertEqual(Recontextualizer.formatPercent(99.6), "100%")
    }

    func testExactPercentageNeverReachesTheCloud() async {
        // AC3: computation is on-device (gemma=nil → zero network), and only a
        // generalized *bucket* may go to the cloud — never the exact percentage.
        let resp = overbought()
        let enriched = await Recontextualizer(gemma: nil).enrich(
            response: resp, holdings: techLedger().holdings
        )
        // The on-device insight carries the precise figure...
        XCTAssertNotNil(enriched.positionInsight?.portfolioPercent)
        // ...but the query-scoped context that would leave the device carries
        // only a coarse bucket label, with no exact percent anywhere in it.
        let profile = ShareableProfile(
            totalValueBucket: "100k-250k",
            sectorWeightsJSON: "{\"technology\":1.0}",
            positionSizeBucketsJSON: "[\"concentrated\"]"
        )
        let scoped = DifferentialPrivacy.scopedContext(
            query: "How is AAPL doing?",
            ledger: techLedger(),
            profile: profile,
            privacyLevel: .moderate
        )
        let bucket = scoped.focus?.first?.positionSize
        XCTAssertEqual(bucket, "concentrated")
        XCTAssertFalse(bucket?.contains("%") ?? false, "an exact percent must not leave the device")
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
