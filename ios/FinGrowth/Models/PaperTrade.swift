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

struct BenchmarkPoint: Codable, Sendable, Equatable, Hashable {
    var date: String  // yyyy-mm-dd
    var close: Double
}

struct BenchmarkSeries: Codable, Sendable, Equatable {
    var symbol: String
    var points: [BenchmarkPoint]
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
        sourceResearchSessionID: UUID? = nil
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
    }

    var sourceAnalysisType: AnalysisType {
        AnalysisType(rawValue: sourceAnalysisTypeRaw) ?? .general
    }
}

// One measured point on the portfolio's value curve. Persisted once per day on
// refresh so the Performance tracker can plot a *real* return-over-time series
// (value vs cost basis at each captured date) rather than projecting today's
// market value onto past dates. ``capturedDay`` is the start-of-day so we can
// dedupe to one snapshot per calendar day.
@Model
final class PortfolioSnapshot {
    @Attribute(.unique) var capturedDay: Date
    var marketValue: Double
    var costBasis: Double

    init(capturedDay: Date, marketValue: Double, costBasis: Double) {
        self.capturedDay = capturedDay
        self.marketValue = marketValue
        self.costBasis = costBasis
    }

    // Cumulative return as a percentage; nil when cost basis is zero (no
    // positions held), since 0/0 return is undefined rather than 0%.
    var returnPct: Double? {
        guard costBasis > 0 else { return nil }
        return (marketValue / costBasis - 1) * 100
    }
}
