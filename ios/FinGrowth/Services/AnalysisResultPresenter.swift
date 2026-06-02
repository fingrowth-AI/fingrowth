import Foundation

// Presentation logic for an analysis result (V10-02).
//
// The result must open on a short, readable conclusion that addresses the
// user's actual question — not a table of indicators. The indicator table is
// demoted to supporting evidence the user can expand below. This type holds the
// view-independent decisions so they're unit-testable; ResearchView renders in
// the order this implies.
enum AnalysisResultPresenter {
    // Indicators are supporting evidence shown *below* the assessment, collapsed
    // by default so a result never opens on a number dump (V10-02 AC1/AC3).
    static let indicatorsInitiallyExpanded = false

    // Whether the question asks about future direction or a buy/sell decision,
    // rather than a factual or indicator lookup. Directional questions earn the
    // honest "no one can reliably predict" framing (AC2).
    static func isDirectionalQuestion(_ query: String) -> Bool {
        let q = query.lowercased()
        let cues = [
            "will ", "going to", "go up", "go down", "gonna", "rise", "rally",
            "fall", "drop", "crash", "moon", "should i buy", "should i sell",
            "should i hold", "is it a buy", "is it a sell", "good time to buy",
            "good time to sell", "worth buying", "worth selling", "predict",
            "forecast", "outlook", "price target", "headed", "next week",
            "next month", "tomorrow",
        ]
        return cues.contains { q.contains($0) }
    }

    // The plain-language conclusion shown at the TOP of a result. Leads with the
    // analyst narrative (V10-01). For a directional question it guarantees the
    // honest no-prediction framing is present even if the narrative didn't spell
    // it out — never a bare number dump. Falls back to a readable line when the
    // narrative is empty (e.g. a degraded result), pointing at the evidence below.
    static func leadAssessment(narrative: String, query: String) -> String {
        let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty
            ? "We couldn't produce an assessment for this question — the supporting "
                + "indicators are below."
            : trimmed
        guard isDirectionalQuestion(query) else { return base }
        // Avoid double-hedging: the V10-01 narrative usually already states that
        // no single indicator predicts direction.
        if base.lowercased().contains("predict") {
            return base
        }
        return "No one can reliably predict where the price goes next, but here's "
            + "what the signals suggest. " + base
    }
}
