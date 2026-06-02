import XCTest
import SwiftData
@testable import FinGrowth

// Tests for V12-01 — Thesis capture on paper trades.
//
// Acceptance criteria:
//   * Thesis field is required before a paper order can be placed.
//   * Side toggle defaults to unselected; the user must choose.
//   * Thesis text is stored with the order and the linked analysis session_id.
final class PaperTradeThesisTests: XCTestCase {

    // MARK: - AC1/AC2: order-placement validation

    func testThesisIsRequiredBeforePlacingAnOrder() {
        // AC1: a blank thesis blocks the order; non-blank allows it.
        XCTAssertFalse(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: true, quantity: 3, thesis: ""))
        XCTAssertFalse(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: true, quantity: 3, thesis: "   \n  "))
        XCTAssertTrue(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: true, quantity: 3, thesis: "Mean reversion after the dip"))
    }

    func testSideMustBeExplicitlyChosen() {
        // AC2: with no side selected the order can't be placed, regardless of the
        // rest being valid. (The view's @State side starts nil → sideSelected=false.)
        XCTAssertFalse(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: false, quantity: 3, thesis: "Momentum"))
        XCTAssertTrue(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: true, quantity: 3, thesis: "Momentum"))
    }

    func testTickerAndPositiveQuantityStillRequired() {
        XCTAssertFalse(PaperOrderForm.canPlace(
            ticker: "  ", sideSelected: true, quantity: 3, thesis: "x"))
        XCTAssertFalse(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: true, quantity: 0, thesis: "x"))
        XCTAssertFalse(PaperOrderForm.canPlace(
            ticker: "AAPL", sideSelected: true, quantity: nil, thesis: "x"))
    }

    // MARK: - AC3: thesis stored with the order + linked session_id

    @MainActor
    func testPlaceOrderPersistsThesisAndLinkedSessionID() async throws {
        let container = try ModelContainer(
            for: PaperTradeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let sessionID = UUID()
        let store = PortfolioStore(client: StubPaperTradingService(order: Self.order()), context: context)
        let source = PaperTradePrefill.Pending(
            ticker: "AAPL",
            sourceQuery: "Is AAPL overbought?",
            sourceAnalysisType: .technical,
            sourceConfidence: "moderate",
            sourceResearchSessionID: sessionID
        )

        _ = await store.placeOrder(
            ticker: "AAPL",
            qty: 3,
            side: "buy",
            thesis: "  Mean reversion after the dip.  ",
            source: source
        )

        let records = try context.fetch(FetchDescriptor<PaperTradeRecord>())
        XCTAssertEqual(records.count, 1)
        // Stored with the order, trimmed of surrounding whitespace.
        XCTAssertEqual(records.first?.thesis, "Mean reversion after the dip.")
        // ...and linked to the analysis session that prompted it.
        XCTAssertEqual(records.first?.sourceResearchSessionID, sessionID)
    }

    @MainActor
    func testPlaceOrderRejectsBlankThesisWithoutHittingTheNetwork() async throws {
        // Defense-in-depth: the store — the real order-placement chokepoint —
        // refuses a blank thesis, so no backend order is placed and nothing is
        // persisted, even if a caller bypasses the order form.
        let container = try ModelContainer(
            for: PaperTradeRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let client = StubPaperTradingService(order: Self.order())
        let store = PortfolioStore(client: client, context: context)

        let order = await store.placeOrder(ticker: "AAPL", qty: 3, side: "buy", thesis: "   \n  ")

        XCTAssertNil(order, "a blank thesis must not produce an order")
        XCTAssertEqual(client.placeOrderCallCount, 0, "no network call should be made")
        XCTAssertNotNil(store.submitError)
        let records = try context.fetch(FetchDescriptor<PaperTradeRecord>())
        XCTAssertTrue(records.isEmpty, "no local record should be persisted")
    }

    func testNewPaperTradeRecordDefaultsToEmptyThesis() {
        // Migration safety: a record created without a thesis is "" not a crash.
        let record = PaperTradeRecord(
            brokerOrderID: "o1", ticker: "AAPL", qty: 1, side: "buy",
            status: "accepted", submittedAt: Date()
        )
        XCTAssertEqual(record.thesis, "")
    }

    // MARK: - Fixtures

    private static func order() -> BrokerOrder {
        BrokerOrder(
            id: "order-1",
            clientOrderId: nil,
            symbol: "AAPL",
            qty: 3,
            side: "buy",
            orderType: "market",
            timeInForce: "day",
            status: "accepted",
            submittedAt: Date(),
            filledQty: 0,
            filledAvgPrice: nil
        )
    }
}

// Minimal stub: placeOrder echoes a canned order and counts how many times it
// was hit (to assert the network call is skipped when validation fails); the
// rest return empties so the fire-and-forget refresh after placement is harmless.
private final class StubPaperTradingService: PaperTradingService, @unchecked Sendable {
    let order: BrokerOrder
    private(set) var placeOrderCallCount = 0

    init(order: BrokerOrder) { self.order = order }

    func listPositions() async throws -> [BrokerPosition] { [] }
    func listOrders(limit: Int, status: String) async throws -> [BrokerOrder] { [order] }
    func placeOrder(_ request: PlacePaperOrderRequest) async throws -> BrokerOrder {
        placeOrderCallCount += 1
        return order
    }
    func benchmark(symbol: String, days: Int) async throws -> BenchmarkSeries {
        BenchmarkSeries(symbol: symbol, points: [])
    }
    func portfolioHistory(period: String, timeframe: String) async throws -> PortfolioHistorySeries {
        PortfolioHistorySeries(baseValue: 0, points: [])
    }
}
