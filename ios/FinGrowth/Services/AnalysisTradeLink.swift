import Foundation
import SwiftData

// V12-03: bidirectional analysis ↔ paper-trade linking.
//
// The link is a single persisted field — PaperTradeRecord.sourceResearchSessionID
// pointing at ResearchHistoryEntry.sessionID — captured when a trade is placed
// from a research result (V12-01). Both directions resolve through that field,
// so the link survives app restarts: it's read back from the SwiftData store,
// not held in memory.
//
// Centralized here (rather than inlined in each view) so the forward and reverse
// lookups share one predicate and are directly unit-testable.
enum AnalysisTradeLink {
    /// The analysis a trade was placed from, or nil when the trade carries no
    /// link or the original entry is gone.
    static func linkedEntry(for trade: PaperTradeRecord, in context: ModelContext) -> ResearchHistoryEntry? {
        guard let sessionID = trade.sourceResearchSessionID else { return nil }
        var descriptor = FetchDescriptor<ResearchHistoryEntry>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Every paper trade placed from a given analysis, newest first.
    static func linkedTrades(forSessionID sessionID: UUID, in context: ModelContext) -> [PaperTradeRecord] {
        let descriptor = FetchDescriptor<PaperTradeRecord>(
            predicate: #Predicate { $0.sourceResearchSessionID == sessionID },
            sortBy: [SortDescriptor(\.submittedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
