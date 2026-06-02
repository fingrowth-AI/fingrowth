import XCTest
@testable import FinGrowth

// Tests for V11-03 — Portfolio-level analysis view.
//
// Acceptance criteria:
//   * A portfolio-level query returns diversification and sector-concentration
//     findings.
//   * The analysis uses query-scoped generalized context, never raw identity.
//   * Findings are interpreted in plain language, consistent with Phase 10.
final class PortfolioAnalyzerTests: XCTestCase {

    // MARK: - Fixtures

    private func profile(sectors: [String: Double], risk: Double? = nil) -> GeneralizedProfile {
        GeneralizedProfile(
            privacyLevel: risk == nil ? .moderate : .detailed,
            sectorWeights: sectors,
            largestPosition: nil,
            diversification: nil,
            riskScore: risk,
            valueBucket: nil
        )
    }

    private func text(_ analysis: PortfolioAnalysis?) -> String {
        guard let analysis else { return "" }
        return ([analysis.lead] + analysis.findings.map(\.detail)).joined(separator: " ")
    }

    // MARK: - Query detection

    func testIsPortfolioLevelQueryDetectsWholeBookQuestions() {
        for q in [
            "How is my whole portfolio doing?",
            "Is my portfolio too concentrated?",
            "How diversified am I?",
            "What's my asset allocation?",
            "Show me my sector mix",
            "How risky is my portfolio?",
        ] {
            XCTAssertTrue(PortfolioAnalyzer.isPortfolioLevelQuery(q), "should be portfolio-level: \(q)")
        }
    }

    func testIsPortfolioLevelQueryIgnoresSingleTickerQuestions() {
        for q in [
            "How is AAPL doing?",
            "Will TSLA go up next week?",
            "Should I look at my AAPL position?",
            "What are NVDA's earnings?",
        ] {
            XCTAssertFalse(PortfolioAnalyzer.isPortfolioLevelQuery(q), "should NOT be portfolio-level: \(q)")
        }
    }

    // MARK: - AC1: diversification + sector-concentration findings

    func testAnalyzeReturnsDiversificationAndConcentrationFindings() {
        // tech 75 / fixed_income 25 → HHI 0.625 → "low" diversification.
        let analysis = PortfolioAnalyzer.analyze(profile(sectors: ["tech": 75, "fixed_income": 25]))
        let kinds = analysis?.findings.map(\.kind) ?? []
        XCTAssertTrue(kinds.contains(.diversification), "missing diversification finding")
        XCTAssertTrue(kinds.contains(.concentration), "missing concentration finding")

        let diversification = analysis?.findings.first { $0.kind == .diversification }
        XCTAssertEqual(diversification?.tag, "Concentrated")

        let concentration = analysis?.findings.first { $0.kind == .concentration }
        XCTAssertTrue(concentration?.detail.lowercased().contains("technology") ?? false, "top sector not named")
        XCTAssertTrue(concentration?.detail.contains("75%") ?? false, "top weight not stated")
    }

    func testWellDiversifiedPortfolioReadsAsDiversified() {
        // Five even sectors → HHI 0.20 → "high" diversification.
        let even = ["tech": 20.0, "financials": 20, "healthcare": 20, "energy": 20, "industrials": 20]
        let analysis = PortfolioAnalyzer.analyze(profile(sectors: even))
        let diversification = analysis?.findings.first { $0.kind == .diversification }
        XCTAssertEqual(diversification?.tag, "Well diversified")
    }

    func testConcentrationNamesTheLargestSector() {
        // financials is largest even though tech is also held.
        let analysis = PortfolioAnalyzer.analyze(profile(sectors: ["financials": 60, "tech": 40]))
        let concentration = analysis?.findings.first { $0.kind == .concentration }
        XCTAssertTrue(concentration?.detail.lowercased().contains("financials") ?? false)
        XCTAssertFalse(concentration?.detail.lowercased().contains("technology") ?? true, "named the wrong sector")
    }

    // MARK: - Risk (only when the privacy level exposes a score)

    func testRiskFindingPresentOnlyWhenScoreAvailable() {
        let withRisk = PortfolioAnalyzer.analyze(profile(sectors: ["tech": 100], risk: 0.8))
        XCTAssertTrue(withRisk?.findings.contains { $0.kind == .risk } ?? false)
        XCTAssertEqual(withRisk?.findings.first { $0.kind == .risk }?.tag, "Aggressive")

        let withoutRisk = PortfolioAnalyzer.analyze(profile(sectors: ["tech": 100]))
        XCTAssertFalse(withoutRisk?.findings.contains { $0.kind == .risk } ?? true,
                       "risk must be omitted when no score is exposed")
    }

    func testRiskOrientationThresholds() {
        XCTAssertEqual(PortfolioAnalyzer.riskOrientation(0.2), "conservative")
        XCTAssertEqual(PortfolioAnalyzer.riskOrientation(0.5), "balanced")
        XCTAssertEqual(PortfolioAnalyzer.riskOrientation(0.9), "aggressive")
    }

    // MARK: - AC2: generalized context, never raw identity

    func testAnalysisUsesGeneralizedContextNeverIdentity() {
        // The analyzer only ever sees a GeneralizedProfile (sector categories +
        // buckets). Its output speaks in sectors and percentages — never a
        // ticker, account number, or holder name.
        let analysis = PortfolioAnalyzer.analyze(profile(sectors: ["tech": 70, "healthcare": 30], risk: 0.5))
        let rendered = text(analysis)
        XCTAssertTrue(rendered.contains("technology"))
        for identityish in ["AAPL", "MSFT", "NVDA", "account", "holder", "shares of"] {
            XCTAssertFalse(rendered.contains(identityish), "leaked specific/identity token: \(identityish)")
        }
    }

    // MARK: - AC3: plain language, never advice (Phase 10)

    func testFindingsAndLeadAreNeverAdvice() {
        let analysis = PortfolioAnalyzer.analyze(profile(sectors: ["tech": 80, "energy": 20], risk: 0.9))
        XCTAssertNotNil(analysis)
        for line in [analysis!.lead] + analysis!.findings.map(\.detail) {
            XCTAssertFalse(Recontextualizer.containsAdvice(line), "advice leaked into: \(line)")
        }
    }

    func testLeadIsPlainLanguageConclusion() {
        let analysis = PortfolioAnalyzer.analyze(profile(sectors: ["tech": 75, "fixed_income": 25]))
        // Leads with a readable conclusion naming the shape + the largest area.
        XCTAssertTrue(analysis?.lead.contains("concentrated") ?? false)
        XCTAssertTrue(analysis?.lead.contains("technology") ?? false)
        XCTAssertFalse(analysis?.disclaimer.isEmpty ?? true, "every analysis carries a disclaimer")
    }

    // MARK: - P1: whole portfolio spans every imported ledger

    func testCombinedProfileSpansAllImportedLedgers() {
        // A whole-portfolio overview must span every imported account, not just
        // the newest. The newest account is all tech; an older, larger account is
        // all financials — so the *combined* book is financials-led.
        let newestAccount = [LedgerHolding(ticker: "AAPL", quantity: 100, costBasis: 100)]  // $10k tech
        let olderAccount = [LedgerHolding(ticker: "JPM", quantity: 200, costBasis: 400)]    // $80k financials

        let combined = PortfolioAnalyzer.analyze(
            DifferentialPrivacy.generalize(
                profile: CSVPrivacyParser.makeShareableProfile(from: newestAccount + olderAccount, now: .now),
                privacyLevel: .moderate
            )
        )
        let topSector = combined?.findings.first { $0.kind == .concentration }?.detail.lowercased() ?? ""
        XCTAssertTrue(topSector.contains("financials"), "combined book should be financials-led: \(topSector)")

        // Sanity: the newest account alone would have read as technology-led —
        // which is exactly the bug if only profiles.first were analyzed.
        let newestOnly = PortfolioAnalyzer.analyze(
            DifferentialPrivacy.generalize(
                profile: CSVPrivacyParser.makeShareableProfile(from: newestAccount, now: .now),
                privacyLevel: .moderate
            )
        )
        let newestTop = newestOnly?.findings.first { $0.kind == .concentration }?.detail.lowercased() ?? ""
        XCTAssertTrue(newestTop.contains("technology"), "newest-only should be tech-led: \(newestTop)")
    }

    // MARK: - Empty / missing

    func testAnalyzeNilWhenNoSectorWeights() {
        XCTAssertNil(PortfolioAnalyzer.analyze(profile(sectors: [:])))
        XCTAssertNil(PortfolioAnalyzer.analyze(profile(sectors: ["tech": 0])))
    }
}
