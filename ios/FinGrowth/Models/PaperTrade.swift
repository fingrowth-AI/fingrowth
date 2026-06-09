import Foundation
import SwiftData

// Wire-side mirrors of the backend models in app/models/trading.py and the
// /paper-trades/* router responses. Names use snake_case on the wire; the
// JSONDecoder used by PaperTradingClient converts to camelCase here.

struct BrokerOrder: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var clientOrderId: String?
    var symbol: String
    var qty: Double
    var side: String  // "buy" | "sell"
    var orderType: String
    var timeInForce: String
    var status: String
    var submittedAt: Date?
    var filledQty: Double
    var filledAvgPrice: Double?
}

struct BrokerPosition: Codable, Sendable, Equatable, Identifiable, Hashable {
    var symbol: String
    var qty: Double
    var side: String  // "long" | "short"
    var avgEntryPrice: Double
    var marketValue: Double?
    var costBasis: Double?
    var unrealizedPl: Double?

    var id: String { symbol }
}

// One day of the per-user equity curve aligned to the benchmark, from
// /api/v1/paper/performance (V8-04). The backend reconstructs equity from the
// user's own trade log and virtual cash — never Alpaca's account-level
// history — and samples it on the benchmark's trading days, so the two series
// overlay on one chart. Returns are cumulative fractions vs. the window's
// first day (0.05 == +5%); realized P/L is carried forward, so closed trades
// stay in the curve.
struct PerformancePoint: Codable, Sendable, Equatable, Hashable {
    var date: String  // yyyy-mm-dd
    var equity: Double
    var portfolioReturn: Double
    var benchmarkReturn: Double
}

struct PerformanceComparison: Codable, Sendable, Equatable {
    var benchmarkSymbol: String
    var baseEquity: Double
    var points: [PerformancePoint]
}

// MARK: - SwiftData record

// Local record of a paper trade *we* placed, with the link back to the
// research run that prompted it (P4-04 acceptance: "tapping a paper trade
// shows the linked analysis"). The source fields are denormalized snapshots
// rather than a relationship so a deleted ResearchHistoryEntry doesn't leave
// the trade orphaned with a dangling reference.
@Model
final class PaperTradeRecord {
    @Attribute(.unique) var brokerOrderID: String
    var ticker: String
    var qty: Double
    var side: String
    var status: String
    var submittedAt: Date
    var filledQty: Double
    var filledAvgPrice: Double?

    var sourceQuery: String
    var sourceAnalysisTypeRaw: String
    var sourceConfidence: String
    // Backend session ID of the linked ResearchHistoryEntry. UUID rather than
    // PersistentIdentifier because SwiftData rejects PersistentIdentifier as
    // a stored property.
    var sourceResearchSessionID: UUID?
    // V12-01: the user's own short rationale for the trade, required at order
    // time. Captured here (on-device) alongside the linked session ID so the
    // research-to-outcome loop (V12-02) has substance to check against. Default
    // "" so the V6 → V7 migration is lightweight for any pre-thesis rows.
    var thesis: String = ""

    init(
        brokerOrderID: String,
        ticker: String,
        qty: Double,
        side: String,
        status: String,
        submittedAt: Date,
        filledQty: Double = 0,
        filledAvgPrice: Double? = nil,
        sourceQuery: String = "",
        sourceAnalysisType: AnalysisType = .general,
        sourceConfidence: String = "",
        sourceResearchSessionID: UUID? = nil,
        thesis: String = ""
    ) {
        self.brokerOrderID = brokerOrderID
        self.ticker = ticker.uppercased()
        self.qty = qty
        self.side = side
        self.status = status
        self.submittedAt = submittedAt
        self.filledQty = filledQty
        self.filledAvgPrice = filledAvgPrice
        self.sourceQuery = sourceQuery
        self.sourceAnalysisTypeRaw = sourceAnalysisType.rawValue
        self.sourceConfidence = sourceConfidence
        self.sourceResearchSessionID = sourceResearchSessionID
        self.thesis = thesis
    }

    var sourceAnalysisType: AnalysisType {
        AnalysisType(rawValue: sourceAnalysisTypeRaw) ?? .general
    }
}
