import XCTest
@testable import FinGrowth

// Tests for V12-05 — Onboarding, query help, and empty states.
//
// Acceptance criteria:
//   * First launch shows onboarding covering privacy, framing, and CSV import.
//   * Query input offers ticker autocomplete and example queries.
//   * Portfolio, Privacy, and Research tabs each show a guiding empty state.
final class OnboardingTests: XCTestCase {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "OnboardingTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - AC1: onboarding shows once, then persists as seen

    func testOnboardingUnseenByDefaultThenPersistsAsSeen() {
        let defaults = makeIsolatedDefaults()

        let first = AppSettings(defaults: defaults)
        XCTAssertFalse(first.hasSeenOnboarding, "a fresh install must show onboarding")

        first.hasSeenOnboarding = true
        let second = AppSettings(defaults: defaults)
        XCTAssertTrue(second.hasSeenOnboarding, "once seen, onboarding must not reappear")
    }

    func testOnboardingCoversPrivacyFramingAndCSVImport() {
        let topics = Set(OnboardingContent.pages.map(\.topic))
        XCTAssertEqual(topics, [.privacy, .framing, .csvImport],
                       "onboarding must cover privacy, research-not-advice framing, and CSV import")
        // Each page has presentable content.
        for page in OnboardingContent.pages {
            XCTAssertFalse(page.title.isEmpty)
            XCTAssertFalse(page.body.isEmpty)
            XCTAssertFalse(page.systemImage.isEmpty)
        }
    }

    func testPrivacyCopyIsAccurateAboutWhatStaysAndWhatMaySend() {
        let byTopic = Dictionary(uniqueKeysWithValues: OnboardingContent.pages.map { ($0.topic, $0) })
        let privacy = (byTopic[.privacy]?.body ?? "").lowercased()
        XCTAssertTrue(privacy.contains("on-device"))
        // Names what actually stays on-device (identity / raw rows).
        XCTAssertTrue(privacy.contains("account numbers"))
        // ...and is honest that *some* generalized context is sent (Phase 9).
        XCTAssertTrue(privacy.contains("query-relevant") || privacy.contains("generalized"))
        // Must NOT make the over-absolute claim that holdings are never sent.
        XCTAssertFalse(privacy.contains("never your holdings"))
        XCTAssertFalse(privacy.contains("never receives your holdings"))

        XCTAssertTrue((byTopic[.framing]?.body.lowercased().contains("never")) ?? false)
        XCTAssertTrue((byTopic[.csvImport]?.body.lowercased().contains("csv")) ?? false)
    }

    // MARK: - AC2: example queries are offered

    func testExampleQueriesAreOffered() {
        XCTAssertGreaterThanOrEqual(ResearchExamples.all.count, 3)
        XCTAssertFalse(ResearchExamples.all.contains { $0.query.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testExampleQueriesSpanTheAnalysisPaths() {
        // The examples should exercise the classifier's paths so they double as a
        // tour of what the app does (V12-04 ↔ V12-05).
        let types = Set(ResearchExamples.all.map { AnalysisTypeClassifier.deterministicClassify(query: $0.query) })
        XCTAssertTrue(types.contains(.technical))
        XCTAssertTrue(types.contains(.fundamental))
        // And at least one whole-portfolio example.
        XCTAssertTrue(ResearchExamples.all.contains { PortfolioAnalyzer.isPortfolioLevelQuery($0.query) })
    }

    func testSingleTickerExamplesAreRunnable() {
        // P2 fix: a non-portfolio example must carry a ticker so Run isn't left
        // disabled; a portfolio-level example needs none.
        for example in ResearchExamples.all {
            if PortfolioAnalyzer.isPortfolioLevelQuery(example.query) {
                XCTAssertNil(example.ticker, "portfolio-level example needs no ticker: \(example.query)")
            } else {
                XCTAssertNotNil(example.ticker, "single-ticker example must fill the ticker: \(example.query)")
                XCTAssertFalse(example.ticker?.isEmpty ?? true)
            }
        }
    }
}
