import XCTest
@testable import FinGrowth

// Tests for V12-04 — Auto-classify analysis type with override.
//
// Acceptance criteria:
//   * A natural-language query is auto-classified into the correct path in the
//     common cases.
//   * The classification is shown and is user-overridable (UI; the override flag
//     lives in ResearchView).
//   * Classification runs on-device (deterministic floor + optional on-device
//     Gemma — no network).
final class AnalysisTypeClassifierTests: XCTestCase {

    private func classify(_ query: String) -> AnalysisType {
        AnalysisTypeClassifier.deterministicClassify(query: query)
    }

    // MARK: - AC1: common cases land on the right path

    func testTechnicalQueries() {
        XCTAssertEqual(classify("Is AAPL overbought? What's the RSI?"), .technical)
        XCTAssertEqual(classify("Has TSLA broken its 200-day moving average?"), .technical)
        XCTAssertEqual(classify("What does the MACD say about NVDA momentum?"), .technical)
        XCTAssertEqual(classify("Show me support and resistance for MSFT"), .technical)
    }

    func testFundamentalQueries() {
        XCTAssertEqual(classify("How were Apple's latest earnings and revenue?"), .fundamental)
        XCTAssertEqual(classify("Is NVDA overvalued on a P/E basis?"), .fundamental)
        XCTAssertEqual(classify("What's Tesla's debt and free cash flow?"), .fundamental)
        XCTAssertEqual(classify("Break down Microsoft's balance sheet and margins"), .fundamental)
    }

    func testEarningsPhrasingsClassifyFundamental() {
        // The bug report's exact phrasing, plus common variants.
        XCTAssertEqual(classify("How were NVDA's latest earnings?"), .fundamental)
        XCTAssertEqual(classify("What happened in the latest quarter?"), .fundamental)
        XCTAssertEqual(classify("How did quarterly results compare to guidance?"), .fundamental)
        XCTAssertEqual(classify("Did net income improve with the new outlook?"), .fundamental)
    }

    func testGeneralQueries() {
        XCTAssertEqual(classify("What's the latest news on NVDA?"), .general)
        XCTAssertEqual(classify("Tell me about Tesla"), .general)
        XCTAssertEqual(classify("Give me an overview of Apple"), .general)
    }

    // MARK: - Scoring edges

    func testMoreCuesWins() {
        // One technical cue vs. two fundamental cues → fundamental.
        XCTAssertEqual(classify("Given the trend, how are earnings and revenue?"), .fundamental)
    }

    func testTieFallsBackToGeneral() {
        // One cue each (RSI vs. earnings) → tie → general.
        XCTAssertEqual(classify("How do the RSI and the earnings look?"), .general)
    }

    func testShortCuesAreWordBoundedNotSubstrings() {
        // "smart"/"steps"/"theme" must NOT trigger sma/eps/ema.
        XCTAssertEqual(classify("Is this a smart company with good steps and a theme?"), .general)
    }

    func testEmptyQueryIsGeneral() {
        XCTAssertEqual(classify(""), .general)
    }

    // MARK: - AC3: ambiguity gate + on-device (no model → deterministic floor)

    func testOnlyGeneralIsAmbiguous() {
        XCTAssertTrue(AnalysisTypeClassifier.isAmbiguous(.general))
        XCTAssertFalse(AnalysisTypeClassifier.isAmbiguous(.technical))
        XCTAssertFalse(AnalysisTypeClassifier.isAmbiguous(.fundamental))
    }

    func testClassifyWithoutModelReturnsDeterministicFloor() async {
        // gemma == nil → no network, deterministic result stands.
        let result = await AnalysisTypeClassifier(gemma: nil).classify(query: "Is AAPL overbought on RSI?")
        XCTAssertEqual(result, .technical)
    }
}
