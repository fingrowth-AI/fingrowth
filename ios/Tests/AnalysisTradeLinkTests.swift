import XCTest
import SwiftData
@testable import FinGrowth

// Tests for V12-03 — Bidirectional analysis ↔ paper-trade linking.
//
// Acceptance criteria:
//   * Tapping a paper trade opens its linked analysis (forward link).
//   * An analysis that led to a trade shows a link to that trade (reverse link).
//   * Links survive app restarts (persisted, per user).
final class AnalysisTradeLinkTests: XCTestCase {

    // MARK: - Fixtures

    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fingrowth-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "store.sqlite")
    }

    private func makeEntry(sessionID: UUID) -> ResearchHistoryEntry {
        ResearchHistoryEntry(
            sessionID: sessionID,
            createdAt: Date(),
            ticker: "AAPL",
            query: "Is AAPL overbought?",
            analysisType: .technical,
            narrative: "Momentum looks elevated.",
            confidence: "moderate",
            disclaimer: "Research only.",
            indicatorsJSON: Data("{}".utf8),
            riskFlagsJSON: Data("[]".utf8),
            riskApproved: true,
            riskModifiedResponse: ""
        )
    }

    private func makeTrade(_ id: String, session: UUID?, day: Int = 1) -> PaperTradeRecord {
        PaperTradeRecord(
            brokerOrderID: id,
            ticker: "AAPL",
            qty: 5,
            side: "buy",
            status: "filled",
            submittedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
            sourceResearchSessionID: session,
            thesis: "bullish"
        )
    }

    // MARK: - AC1 + AC2: both directions resolve

    @MainActor
    func testForwardAndReverseLinksResolve() throws {
        let context = ModelContext(try AppContainer.makeContainer(storeURL: tempStoreURL()))
        let sessionID = UUID()
        let entry = makeEntry(sessionID: sessionID)
        let trade = makeTrade("o1", session: sessionID)
        context.insert(entry)
        context.insert(trade)
        try context.save()

        // Forward (AC1): a trade resolves to the analysis that inspired it.
        XCTAssertEqual(AnalysisTradeLink.linkedEntry(for: trade, in: context)?.sessionID, sessionID)
        // Reverse (AC2): the analysis resolves to the trade it led to.
        XCTAssertEqual(
            AnalysisTradeLink.linkedTrades(forSessionID: sessionID, in: context).map(\.brokerOrderID),
            ["o1"]
        )
    }

    @MainActor
    func testReverseLinkIsNewestFirstAndScopedToTheAnalysis() throws {
        let context = ModelContext(try AppContainer.makeContainer(storeURL: tempStoreURL()))
        let s1 = UUID()
        let s2 = UUID()
        context.insert(makeEntry(sessionID: s1))
        context.insert(makeEntry(sessionID: s2))
        context.insert(makeTrade("a", session: s1, day: 1))
        context.insert(makeTrade("b", session: s2, day: 2))  // different analysis
        context.insert(makeTrade("c", session: s1, day: 3))
        try context.save()

        let s1Trades = AnalysisTradeLink.linkedTrades(forSessionID: s1, in: context)
        // Only s1's trades, newest first.
        XCTAssertEqual(s1Trades.map(\.brokerOrderID), ["c", "a"])
    }

    @MainActor
    func testUnlinkedTradeAndEmptyAnalysisResolveToNothing() throws {
        let context = ModelContext(try AppContainer.makeContainer(storeURL: tempStoreURL()))
        let trade = makeTrade("o1", session: nil)  // placed without a linked analysis
        context.insert(trade)
        try context.save()

        XCTAssertNil(AnalysisTradeLink.linkedEntry(for: trade, in: context))
        XCTAssertTrue(AnalysisTradeLink.linkedTrades(forSessionID: UUID(), in: context).isEmpty)
    }

    // MARK: - AC3: links survive a restart

    @MainActor
    func testLinkSurvivesAppRestart() throws {
        let url = try tempStoreURL()
        let sessionID = UUID()

        // First launch: place a trade linked to an analysis, then tear down.
        do {
            let context = ModelContext(try AppContainer.makeContainer(storeURL: url))
            context.insert(makeEntry(sessionID: sessionID))
            context.insert(makeTrade("o1", session: sessionID))
            try context.save()
        }

        // Relaunch: a fresh container over the same store must still resolve both
        // directions from disk — the link wasn't just in memory.
        let reopened = ModelContext(try AppContainer.makeContainer(storeURL: url))
        let trades = AnalysisTradeLink.linkedTrades(forSessionID: sessionID, in: reopened)
        XCTAssertEqual(trades.count, 1)
        XCTAssertEqual(AnalysisTradeLink.linkedEntry(for: trades[0], in: reopened)?.sessionID, sessionID)
    }
}
