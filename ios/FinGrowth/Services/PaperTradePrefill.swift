import Foundation
import Observation

// Shared state used by ResearchView to hand a ticker (and the analysis it came
// from) off to the Portfolio tab's paper-trade order form. The full paper
// trading flow lives in P4-04 / P2-05; this controller is the prefill bridge
// the P4-03 acceptance criteria require ("'Test with paper trade' pre-fills
// order form with relevant ticker").
@MainActor
@Observable
final class PaperTradePrefill {
    struct Pending: Equatable {
        var ticker: String
        var sourceQuery: String
        var sourceAnalysisType: AnalysisType
        var sourceConfidence: String
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
