import XCTest
@testable import FinGrowth

// Tests for V12-02 — Outcome tracking and personal hit-rate.
//
// Acceptance criteria:
//   * Closed trade shows a thesis-confirmed / not-confirmed result via a
//     deterministic direction check.
//   * A running hit-rate across the user's closed theses is displayed.
//   * Outcome labeling is not an LLM judgment (pure arithmetic on fills).
final class ThesisOutcomeEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func trade(
        _ id: String,
        _ ticker: String,
        side: String,
        qty: Double,
        fill: Double?,
        day: Int,
        thesis: String = "thesis"
    ) -> PaperTradeRecord {
        PaperTradeRecord(
            brokerOrderID: id,
            ticker: ticker,
            qty: qty,
            side: side,
            status: fill == nil ? "accepted" : "filled",
            submittedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            filledQty: fill == nil ? 0 : qty,
            filledAvgPrice: fill,
            thesis: thesis
        )
    }

    // MARK: - AC1/AC3: deterministic direction check

    func testEvaluateLongThesis() {
        XCTAssertEqual(ThesisOutcomeEngine.evaluate(openingSide: "buy", entryPrice: 150, exitPrice: 165), .confirmed)
        XCTAssertEqual(ThesisOutcomeEngine.evaluate(openingSide: "buy", entryPrice: 150, exitPrice: 140), .notConfirmed)
        XCTAssertEqual(ThesisOutcomeEngine.evaluate(openingSide: "buy", entryPrice: 150, exitPrice: 150), .notConfirmed)
    }

    func testEvaluateShortThesis() {
        XCTAssertEqual(ThesisOutcomeEngine.evaluate(openingSide: "sell", entryPrice: 150, exitPrice: 130), .confirmed)
        XCTAssertEqual(ThesisOutcomeEngine.evaluate(openingSide: "sell", entryPrice: 150, exitPrice: 170), .notConfirmed)
        XCTAssertEqual(ThesisOutcomeEngine.evaluate(openingSide: "sell", entryPrice: 150, exitPrice: 150), .notConfirmed)
    }

    // MARK: - Round-trip matching → closed theses

    func testProfitableLongRoundTripIsConfirmed() {
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: 150, day: 1, thesis: "bullish on earnings"),
            trade("c1", "AAPL", side: "sell", qty: 10, fill: 165, day: 2),
        ]
        let closed = ThesisOutcomeEngine.closedTheses(from: records)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.openingOrderID, "o1")  // attributed to the opening order
        XCTAssertEqual(closed.first?.thesis, "bullish on earnings")
        XCTAssertEqual(closed.first?.outcome, .confirmed)
    }

    func testLosingLongRoundTripIsNotConfirmed() {
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: 150, day: 1),
            trade("c1", "AAPL", side: "sell", qty: 10, fill: 140, day: 2),
        ]
        XCTAssertEqual(ThesisOutcomeEngine.closedTheses(from: records).first?.outcome, .notConfirmed)
    }

    func testShortRoundTripConfirmedWhenPriceFalls() {
        let records = [
            trade("o1", "TSLA", side: "sell", qty: 5, fill: 200, day: 1, thesis: "overvalued"),
            trade("c1", "TSLA", side: "buy", qty: 5, fill: 180, day: 2),
        ]
        let closed = ThesisOutcomeEngine.closedTheses(from: records)
        XCTAssertEqual(closed.first?.openingSide, "sell")
        XCTAssertEqual(closed.first?.outcome, .confirmed)
    }

    func testOpenPositionProducesNoClosedThesis() {
        // A buy with no matching sell is still open — not yet decidable.
        let records = [trade("o1", "AAPL", side: "buy", qty: 10, fill: 150, day: 1)]
        XCTAssertTrue(ThesisOutcomeEngine.closedTheses(from: records).isEmpty)
    }

    func testUnfilledOrdersAreIgnored() {
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: nil, day: 1),   // accepted, not filled
            trade("c1", "AAPL", side: "sell", qty: 10, fill: nil, day: 2),
        ]
        XCTAssertTrue(ThesisOutcomeEngine.closedTheses(from: records).isEmpty)
    }

    func testPartialClosesUseQuantityWeightedExit() {
        // Buy 10 @100; sell 4 @120 and 6 @90 → weighted exit (480+540)/10 = 102 > 100.
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: 100, day: 1),
            trade("c1", "AAPL", side: "sell", qty: 4, fill: 120, day: 2),
            trade("c2", "AAPL", side: "sell", qty: 6, fill: 90, day: 3),
        ]
        let closed = ThesisOutcomeEngine.closedTheses(from: records)
        XCTAssertEqual(closed.count, 1, "one outcome per opening order")
        XCTAssertEqual(closed.first?.exitPrice ?? 0, 102, accuracy: 0.001)
        XCTAssertEqual(closed.first?.outcome, .confirmed)
    }

    func testDistinctTickersDoNotMatchEachOther() {
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: 150, day: 1),
            trade("o2", "MSFT", side: "sell", qty: 10, fill: 300, day: 2),
        ]
        // Opposite sides but different tickers → no round trip closes.
        XCTAssertTrue(ThesisOutcomeEngine.closedTheses(from: records).isEmpty)
    }

    func testPartiallyClosedPositionIsNotYetAClosedThesis() {
        // P1: buy 10, sell only 1 → the thesis is still 9 shares open, so it must
        // not be scored or counted until the whole position is closed.
        let partial = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: 100, day: 1),
            trade("c1", "AAPL", side: "sell", qty: 1, fill: 120, day: 2),
        ]
        XCTAssertTrue(ThesisOutcomeEngine.closedTheses(from: partial).isEmpty,
                      "a partially closed position is not a closed thesis")

        // Selling the remaining 9 completes the round trip → now it's scored.
        let completed = partial + [trade("c2", "AAPL", side: "sell", qty: 9, fill: 130, day: 3)]
        let closed = ThesisOutcomeEngine.closedTheses(from: completed)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.quantity ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(closed.first?.outcome, .confirmed)  // weighted exit 129 > 100
    }

    func testRoundTripWithoutAThesisIsExcluded() {
        // P2: a legacy/blank-thesis opening order is a round trip but not a
        // *thesis* — it must not be scored, badged, or counted.
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 10, fill: 100, day: 1, thesis: "   "),
            trade("c1", "AAPL", side: "sell", qty: 10, fill: 120, day: 2),
        ]
        XCTAssertTrue(ThesisOutcomeEngine.closedTheses(from: records).isEmpty)
    }

    // MARK: - AC2: running hit-rate

    func testHitRateAcrossClosedTheses() {
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 1, fill: 100, day: 1),
            trade("c1", "AAPL", side: "sell", qty: 1, fill: 120, day: 2),   // confirmed
            trade("o2", "MSFT", side: "buy", qty: 1, fill: 300, day: 3),
            trade("c2", "MSFT", side: "sell", qty: 1, fill: 280, day: 4),   // not confirmed
            trade("o3", "NVDA", side: "buy", qty: 1, fill: 500, day: 5),    // still open
        ]
        let hitRate = ThesisOutcomeEngine.hitRate(ThesisOutcomeEngine.closedTheses(from: records))
        XCTAssertEqual(hitRate.confirmed, 1)
        XCTAssertEqual(hitRate.total, 2, "open NVDA position is not counted")
        XCTAssertEqual(hitRate.display, "1/2 confirmed (50%)")
    }

    func testHitRateEmptyWhenNothingClosed() {
        let hitRate = ThesisOutcomeEngine.hitRate([])
        XCTAssertEqual(hitRate.total, 0)
        XCTAssertEqual(hitRate.display, "No closed theses yet")
    }

    func testOutcomesByOpeningOrderIDMapsClosedTrades() {
        let records = [
            trade("o1", "AAPL", side: "buy", qty: 1, fill: 100, day: 1),
            trade("c1", "AAPL", side: "sell", qty: 1, fill: 120, day: 2),
        ]
        let map = ThesisOutcomeEngine.outcomesByOpeningOrderID(from: records)
        XCTAssertEqual(map["o1"], .confirmed)
        XCTAssertNil(map["c1"], "the closing leg is not itself a scored thesis")
    }
}
