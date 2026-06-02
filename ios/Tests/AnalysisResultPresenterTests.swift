import XCTest
@testable import FinGrowth

// Tests for V10-02 — lead with a plain-language answer.
//
// Acceptance criteria:
//   * Result top is a plain-language assessment, not a table
//   * A directional question gets an honest "no one can reliably predict, but
//     here is what the signals suggest" answer, not a number dump
//   * Indicators remain accessible below as expandable evidence
//
// The SwiftUI ordering (assessment first, indicators below) is exercised by the
// build; this pins the view-independent decisions that drive it.
final class AnalysisResultPresenterTests: XCTestCase {

    // AC3: indicators are demoted to collapsed, below-the-fold evidence.
    func testIndicatorsAreCollapsedEvidenceByDefault() {
        XCTAssertFalse(AnalysisResultPresenter.indicatorsInitiallyExpanded)
    }

    func testRecognizesDirectionalQuestions() {
        for q in [
            "Will AAPL go up next week?",
            "Should I buy TSLA?",
            "Is it a good time to sell NVDA?",
            "What's the price target for MSFT?",
            "Where is BTC headed?",
        ] {
            XCTAssertTrue(AnalysisResultPresenter.isDirectionalQuestion(q), "expected directional: \(q)")
        }
    }

    func testFactualQuestionsAreNotDirectional() {
        for q in [
            "What is the RSI of AAPL?",
            "How is my portfolio diversified?",
            "Explain MSFT's recent volatility.",
            "What were NVDA's last earnings?",
        ] {
            XCTAssertFalse(AnalysisResultPresenter.isDirectionalQuestion(q), "expected non-directional: \(q)")
        }
    }

    func testDirectionalQuestionGetsHonestNoPredictionFraming() {
        // AC2: a directional question whose narrative didn't already disclaim
        // predictability is prefaced with the honest framing — not a number dump.
        let narrative = "RSI(14) at 72.10 is overbought; MACD line 1.2000 leans bullish."
        let lead = AnalysisResultPresenter.leadAssessment(
            narrative: narrative, query: "Will AAPL go up?"
        )
        XCTAssertTrue(lead.lowercased().contains("no one can reliably predict"))
        XCTAssertTrue(lead.contains(narrative))  // the signal read still follows
    }

    func testHonestFramingNotDuplicatedWhenNarrativeAlreadyHedges() {
        // The V10-01 narrative typically already says no indicator predicts
        // direction — don't prepend a second hedge.
        let narrative = "No single indicator predicts where the price goes next; "
            + "RSI(14) at 55.00 is neutral."
        let lead = AnalysisResultPresenter.leadAssessment(
            narrative: narrative, query: "Should I buy AAPL?"
        )
        XCTAssertEqual(lead, narrative)
    }

    func testNonDirectionalQuestionLeadsWithNarrativeVerbatim() {
        let narrative = "RSI(14) at 55.00 sits in neutral territory."
        let lead = AnalysisResultPresenter.leadAssessment(
            narrative: narrative, query: "What is the RSI of AAPL?"
        )
        XCTAssertEqual(lead, narrative)
    }

    func testEmptyNarrativeFallsBackToReadableLine() {
        let lead = AnalysisResultPresenter.leadAssessment(
            narrative: "   ", query: "What is the RSI of AAPL?"
        )
        XCTAssertTrue(lead.lowercased().contains("couldn't produce"))
        XCTAssertFalse(lead.isEmpty)
    }
}
