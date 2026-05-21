import Foundation
import Observation

// Shared state used by ResearchView to hand a ticker (and the analysis it came
// from) off to the Portfolio tab's paper-trade order form. ``sourceResearchSessionID``
// is captured so P4-04's "tap a paper trade to see the linked analysis"
// flow can resolve the original ResearchHistoryEntry by its session ID.
@MainActor
@Observable
final class PaperTradePrefill {
    struct Pending: Equatable {
        var ticker: String
        var sourceQuery: String
        var sourceAnalysisType: AnalysisType
        var sourceConfidence: String
        var sourceResearchSessionID: UUID?
    }

    var pending: Pending?

    func enqueue(_ pending: Pending) {
        self.pending = pending
    }

    func consume() -> Pending? {
        defer { pending = nil }
        return pending
    }
}
