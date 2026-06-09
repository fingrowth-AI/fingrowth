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

    // MARK: - Result redesign: verdict line

    func testVerdictLineUsesBackendVerdictWhenPresent() {
        let line = AnalysisResultPresenter.verdictLine(
            verdict: "AAPL looks stretched — momentum is positive but RSI has run hot.",
            narrative: "RSI(14) at 72.10 is overbought.",
            query: "How is AAPL?"
        )
        XCTAssertEqual(line, "AAPL looks stretched — momentum is positive but RSI has run hot.")
    }

    func testVerdictLineFallsBackToLeadWhenVerdictEmpty() {
        // General route has no verdict → falls back to the lead assessment.
        let narrative = "Here's the recent research coverage for TSLA."
        let line = AnalysisResultPresenter.verdictLine(
            verdict: "  ", narrative: narrative, query: "what's the news?"
        )
        XCTAssertEqual(line, narrative)
    }

    // MARK: - Result redesign: signal-at-a-glance pills

    private func technical(rsi: Double?, histogram: Double?, close: Double?, upper: Double?, lower: Double?) -> [String: JSONValue] {
        var t: [String: JSONValue] = [:]
        if let rsi { t["rsi"] = .double(rsi) }
        if let histogram { t["macd"] = .object(["histogram": .double(histogram)]) }
        if let close { t["latest_close"] = .double(close) }
        if let upper, let lower { t["bollinger"] = .object(["upper": .double(upper), "lower": .double(lower)]) }
        return t
    }

    func testSignalPillsMapStatesAndTones() {
        let pills = AnalysisResultPresenter.signalPills(
            from: technical(rsi: 75, histogram: 1.2, close: 110, upper: 108, lower: 92)
        )
        let byIndicator = Dictionary(uniqueKeysWithValues: pills.map { ($0.indicator, $0) })
        XCTAssertEqual(byIndicator["RSI"]?.state, "Overbought")
        XCTAssertEqual(byIndicator["RSI"]?.tone, .caution)        // amber
        XCTAssertEqual(byIndicator["MACD"]?.state, "Bullish")
        XCTAssertEqual(byIndicator["MACD"]?.tone, .positive)      // green
        XCTAssertEqual(byIndicator["Bands"]?.state, "Above")
        XCTAssertEqual(byIndicator["Bands"]?.tone, .caution)      // amber (stretched)
    }

    func testSignalPillsNeutralAndBearish() {
        let pills = AnalysisResultPresenter.signalPills(
            from: technical(rsi: 50, histogram: -1.0, close: 100, upper: 110, lower: 90)
        )
        let byIndicator = Dictionary(uniqueKeysWithValues: pills.map { ($0.indicator, $0) })
        XCTAssertEqual(byIndicator["RSI"]?.tone, .neutral)        // gray
        XCTAssertEqual(byIndicator["MACD"]?.state, "Bearish")
        XCTAssertEqual(byIndicator["MACD"]?.tone, .caution)
        XCTAssertEqual(byIndicator["Bands"]?.state, "Within")
        XCTAssertEqual(byIndicator["Bands"]?.tone, .neutral)
    }

    func testSignalPillsOmitMissingIndicators() {
        let pills = AnalysisResultPresenter.signalPills(from: technical(
            rsi: 60, histogram: nil, close: nil, upper: nil, lower: nil
        ))
        XCTAssertEqual(pills.map(\.indicator), ["RSI"])
    }

    // MARK: - Narrative decomposition (chat-style sections)

    private static let generalNarrative = "Here's the recent research coverage for TSLA: "
        + "3 recent news items and 2 filings. Headlines reportedly in focus: "
        + "“Tesla unveils new model”; “Tesla reports quarterly results”; "
        + "“Tesla expands factory”. This is a research summary for informational "
        + "purposes and not advice; open the sources below for detail."

    func testGeneralResultLeadsWithOneLineTakeaway() {
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "", narrative: Self.generalNarrative, query: "what's the news on TSLA?"
        )
        XCTAssertEqual(
            presentation.takeaway,
            "Here's the recent research coverage for TSLA: 3 recent news items and 2 filings."
        )
    }

    func testGeneralResultHeadlinesBecomeScannableBullets() {
        // The TSLA case from the bug report: three headlines crammed into one
        // paragraph must come out as separate list items.
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "", narrative: Self.generalNarrative, query: "what's the news on TSLA?"
        )
        let news = presentation.sections.first { $0.header == "In the news" }
        XCTAssertEqual(news?.bullets, [
            "Tesla unveils new model",
            "Tesla reports quarterly results",
            "Tesla expands factory",
        ])
    }

    func testGeneralResultPrefersStructuredHeadlinesWhenAvailable() {
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "", narrative: Self.generalNarrative, query: "news?",
            newsHeadlines: ["Exact headline. With punctuation; intact"]
        )
        let news = presentation.sections.first { $0.header == "In the news" }
        XCTAssertEqual(news?.bullets, ["Exact headline. With punctuation; intact"])
    }

    func testGeneralResultFramingLandsInContextNotDetail() {
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "", narrative: Self.generalNarrative, query: "news?"
        )
        let context = presentation.sections.first { $0.header == "Context" }
        XCTAssertTrue(context?.prose.contains("not advice") ?? false)
        // Nothing left over as a "Detail" wall — the takeaway + bullets +
        // context cover the whole narrative.
        XCTAssertNil(presentation.sections.first { $0.header == "Detail" })
    }

    func testNoHeadlineSectionWithoutTheMarkerSentence() {
        // A technical narrative never lists headlines inline; passing the
        // research packet's news must not invent an "In the news" section.
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "AAPL looks steady.",
            narrative: "RSI(14) at 55.00 sits in neutral territory.",
            query: "How is AAPL?",
            newsHeadlines: ["Unrelated headline"]
        )
        XCTAssertNil(presentation.sections.first { $0.header == "In the news" })
    }

    func testTechnicalNarrativeSplitsIntoDetailBulletsAndContext() {
        let narrative = "Technical read for AAPL from 60 daily closes. "
            + "RSI(14) at 72.10 is in overbought territory (above 70). "
            + "No single indicator predicts where the price goes next; these "
            + "describe current conditions, not a recommendation. "
            + "Context: 3 recent news items considered."
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "AAPL looks stretched — RSI is overbought after a strong run.",
            narrative: narrative,
            query: "How is AAPL?"
        )
        // The backend verdict is the takeaway; the narrative is all detail.
        XCTAssertEqual(presentation.takeaway, "AAPL looks stretched — RSI is overbought after a strong run.")
        let detail = presentation.sections.first { $0.header == "Detail" }
        // Sentence splitting must not break on the decimal in "72.10".
        XCTAssertEqual(detail?.bullets, [
            "Technical read for AAPL from 60 daily closes.",
            "RSI(14) at 72.10 is in overbought territory (above 70).",
        ])
        let context = presentation.sections.first { $0.header == "Context" }
        XCTAssertTrue(context?.prose.contains("not a recommendation") ?? false)
        XCTAssertTrue(context?.prose.contains("3 recent news items") ?? false)
    }

    func testDirectionalGeneralQuestionKeepsHonestFramingInTakeaway() {
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "", narrative: Self.generalNarrative, query: "Will TSLA go up?"
        )
        XCTAssertTrue(presentation.takeaway.lowercased().contains("no one can reliably predict"))
    }

    func testEmptyNarrativePresentationFallsBackGracefully() {
        let presentation = AnalysisResultPresenter.presentation(
            verdict: "", narrative: "  ", query: "What is the RSI of AAPL?"
        )
        XCTAssertTrue(presentation.takeaway.lowercased().contains("couldn't produce"))
        XCTAssertTrue(presentation.sections.isEmpty)
    }

    func testHeadlinesExtractedFromRawNewsItems() {
        let news: [JSONValue] = [
            .object(["headline": .string("First story"), "sentiment_score": .double(0.2)]),
            .object(["headline": .string("  ")]),
            .object(["no_headline": .string("x")]),
            .object(["headline": .string("Second story")]),
        ]
        XCTAssertEqual(AnalysisResultPresenter.headlines(from: news), ["First story", "Second story"])
    }
}
