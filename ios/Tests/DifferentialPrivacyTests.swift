import XCTest
@testable import FinGrowth

// Tests for P5-05 — differential privacy for portfolio context.
//
// Acceptance criteria:
//   * [AAPL: 45%, MSFT: 30%, bonds: 25%] at .minimal → {tech: 75, fixed_income: 25}
//   * .moderate adds {largest_position: 'concentrated', diversification: 'low'}
//   * GeneralizedProfile serialization has zero ticker symbols at .minimal
//   * Identical portfolios with different account numbers → identical profiles
//   * Privacy level is user-configurable in Settings (persisted)
final class DifferentialPrivacyTests: XCTestCase {

    // ShareableProfile carries sector weights; AAPL+MSFT roll up to Information
    // Technology (75%), bonds to Fixed Income (25%).
    private func techAndBondsProfile(id: UUID = UUID()) -> ShareableProfile {
        ShareableProfile(
            id: id,
            totalValueBucket: "50k-250k",
            sectorWeightsJSON: #"{"Information Technology": 75, "Fixed Income": 25}"#,
            riskScore: 0.62
        )
    }

    func testMinimalReturnsCategoryWeightsOnly() {
        let profile = DifferentialPrivacy.generalize(profile: techAndBondsProfile(), privacyLevel: .minimal)
        XCTAssertEqual(profile.sectorWeights["tech"], 75)
        XCTAssertEqual(profile.sectorWeights["fixed_income"], 25)
        XCTAssertEqual(profile.sectorWeights.count, 2)
        // Minimal level exposes nothing beyond sector weights.
        XCTAssertNil(profile.largestPosition)
        XCTAssertNil(profile.diversification)
        XCTAssertNil(profile.riskScore)
        XCTAssertNil(profile.valueBucket)
    }

    func testModerateAddsLargestPositionAndDiversification() {
        let profile = DifferentialPrivacy.generalize(profile: techAndBondsProfile(), privacyLevel: .moderate)
        XCTAssertEqual(profile.largestPosition, "concentrated")  // 75% > 30%
        XCTAssertEqual(profile.diversification, "low")
        XCTAssertNil(profile.riskScore, "risk metrics are detailed-only")
    }

    func testDetailedAddsRiskMetrics() {
        let profile = DifferentialPrivacy.generalize(profile: techAndBondsProfile(), privacyLevel: .detailed)
        XCTAssertEqual(profile.riskScore, 0.62)
        XCTAssertEqual(profile.valueBucket, "50k-250k")
        XCTAssertEqual(profile.largestPosition, "concentrated")
    }

    func testMinimalSerializationHasNoTickerSymbols() throws {
        let profile = DifferentialPrivacy.generalize(profile: techAndBondsProfile(), privacyLevel: .minimal)
        let json = String(data: try JSONEncoder().encode(profile), encoding: .utf8) ?? ""
        for ticker in ["AAPL", "MSFT", "TSLA", "Information Technology", "Fixed Income"] {
            XCTAssertFalse(json.contains(ticker), "leaked \(ticker)")
        }
        XCTAssertTrue(json.contains("tech"))
    }

    func testIdenticalPortfoliosProduceIdenticalProfiles() {
        // Same holdings, different identities (distinct ShareableProfile ids).
        let a = DifferentialPrivacy.generalize(profile: techAndBondsProfile(id: UUID()), privacyLevel: .detailed)
        let b = DifferentialPrivacy.generalize(profile: techAndBondsProfile(id: UUID()), privacyLevel: .detailed)
        XCTAssertEqual(a, b, "generalization must not depend on identity")
    }

    func testPositionBucketBoundaries() {
        XCTAssertEqual(DifferentialPrivacy.positionBucket(forPercent: 0.5), "tiny")
        XCTAssertEqual(DifferentialPrivacy.positionBucket(forPercent: 3), "small")
        XCTAssertEqual(DifferentialPrivacy.positionBucket(forPercent: 10), "moderate")
        XCTAssertEqual(DifferentialPrivacy.positionBucket(forPercent: 20), "large")
        XCTAssertEqual(DifferentialPrivacy.positionBucket(forPercent: 30), "large")
        XCTAssertEqual(DifferentialPrivacy.positionBucket(forPercent: 45), "concentrated")
    }

    func testWellDiversifiedPortfolioReadsHigh() {
        let profile = ShareableProfile(
            totalValueBucket: "50k-250k",
            sectorWeightsJSON: #"{"Information Technology": 20, "Health Care": 20, "Financials": 20, "Energy": 20, "Consumer Staples": 20}"#
        )
        let result = DifferentialPrivacy.generalize(profile: profile, privacyLevel: .moderate)
        XCTAssertEqual(result.diversification, "high")
        XCTAssertEqual(result.largestPosition, "large")  // 20% each
    }

    func testPrivacyLevelPersistsInSettings() {
        let suite = "DiffPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let first = AppSettings(defaults: defaults)
        XCTAssertEqual(first.portfolioPrivacyLevel, .moderate, "defaults to moderate")
        first.portfolioPrivacyLevel = .minimal

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.portfolioPrivacyLevel, .minimal)
    }
}
