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
        // AAPL 45% → concentrated, MSFT 30% → large, bonds 25% → large.
        ShareableProfile(
            id: id,
            totalValueBucket: "50k-250k",
            sectorWeightsJSON: #"{"Information Technology": 75, "Fixed Income": 25}"#,
            riskScore: 0.62,
            positionSizeBucketsJSON: #"["concentrated","large","large"]"#
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
            sectorWeightsJSON: #"{"Information Technology": 20, "Health Care": 20, "Financials": 20, "Energy": 20, "Consumer Staples": 20}"#,
            positionSizeBucketsJSON: #"["large","large","large","large","large"]"#
        )
        let result = DifferentialPrivacy.generalize(profile: profile, privacyLevel: .moderate)
        XCTAssertEqual(result.diversification, "high")
        XCTAssertEqual(result.largestPosition, "large")  // 20% each
    }

    func testLargestPositionReflectsHoldingsNotSectorAggregate() {
        // Five 20% tech holdings aggregate to tech: 100, but no single position
        // is concentrated — largestPosition must read "large", not "concentrated".
        let profile = ShareableProfile(
            totalValueBucket: "50k-250k",
            sectorWeightsJSON: #"{"Information Technology": 100}"#,
            positionSizeBucketsJSON: #"["large","large","large","large","large"]"#
        )
        let result = DifferentialPrivacy.generalize(profile: profile, privacyLevel: .moderate)
        XCTAssertEqual(result.sectorWeights["tech"], 100)
        XCTAssertEqual(result.largestPosition, "large", "must reflect individual positions, not the sector aggregate")
    }

    func testImportPopulatesPositionBucketsConsumedByGeneralize() async throws {
        // End-to-end: a dominant holding yields a "concentrated" largest position.
        let csv = """
        Symbol,Quantity,Average Cost
        AAPL,90,100
        MSFT,10,100
        """
        let imported = try await CSVPrivacyParser.parse(csvData: csv)
        let generalized = DifferentialPrivacy.generalize(profile: imported.profile, privacyLevel: .moderate)
        XCTAssertEqual(generalized.largestPosition, "concentrated")  // AAPL ~90%
    }

    // MARK: - V9-03: query-scoped context

    // TSLA is ~98.9% of value (concentrated); AAPL a small sliver. Carries
    // identity so the no-leak test has something to catch.
    private func ledgerWithIdentity() -> PrivateLedger {
        PrivateLedger(
            accountName: "Brokerage",
            accountNumber: "X12345678",
            accountHolder: "Jane Q Public",
            holdings: [
                LedgerHolding(ticker: "TSLA", quantity: 500, costBasis: 280),
                LedgerHolding(ticker: "AAPL", quantity: 10, costBasis: 150),
            ]
        )
    }

    func testSingleTickerQueryScopesToThatHolding() {
        // AC1: a single-ticker query sends only that holding's specifics + minimal
        // context — not the whole-portfolio sector breakdown.
        let ctx = DifferentialPrivacy.scopedContext(
            query: "Should I sell my 500 shares of TSLA?",
            ledger: ledgerWithIdentity(),
            profile: techAndBondsProfile(),
            privacyLevel: .moderate
        )
        XCTAssertEqual(ctx.focus?.count, 1)               // only the named holding
        XCTAssertEqual(ctx.focus?.first?.ticker, "TSLA")
        XCTAssertEqual(ctx.focus?.first?.sector, "consumer_discretionary")
        XCTAssertEqual(ctx.focus?.first?.positionSize, "concentrated")
        XCTAssertTrue(ctx.sectorWeights.isEmpty)          // breakdown withheld
        XCTAssertEqual(ctx.diversification, "low")        // minimal context only
    }

    func testPortfolioLevelQuerySendsSectorsNotPositions() {
        // AC2: a portfolio-level query sends sector weights + concentration, not
        // per-position focus.
        let ctx = DifferentialPrivacy.scopedContext(
            query: "Is my portfolio too tech-heavy?",
            ledger: ledgerWithIdentity(),
            profile: techAndBondsProfile(),
            privacyLevel: .moderate
        )
        XCTAssertNil(ctx.focus)
        XCTAssertEqual(ctx.sectorWeights["tech"], 75)
        XCTAssertEqual(ctx.diversification, "low")
    }

    func testScopedContextNeverLeaksIdentity() throws {
        // AC3: no Tier 1 identity in the outbound payload (what the audit records).
        let ctx = DifferentialPrivacy.scopedContext(
            query: "How are my 500 shares of TSLA doing?",
            ledger: ledgerWithIdentity(),
            profile: techAndBondsProfile(),
            privacyLevel: .detailed
        )
        let json = String(data: try JSONEncoder().encode(ctx), encoding: .utf8) ?? ""
        for identity in ["X12345678", "Jane", "Public"] {
            XCTAssertFalse(json.contains(identity), "leaked identity: \(identity)")
        }
        XCTAssertTrue(json.contains("TSLA"), "tier 2 ticker is allowed")
    }

    func testFocusAggregatesDuplicateLotsByTicker() {
        // V9-03 guard: a multi-lot holding must collapse to one focus entry with
        // the combined position size — not per-row structure, not an understated
        // bucket. Two TSLA lots of 25% each → one TSLA at the 50% (concentrated)
        // bucket; AAPL fills the rest but isn't in the question.
        let ledger = PrivateLedger(
            accountName: "Brokerage",
            holdings: [
                LedgerHolding(ticker: "TSLA", quantity: 25, costBasis: 100),  // $2,500
                LedgerHolding(ticker: "TSLA", quantity: 25, costBasis: 100),  // $2,500 (2nd lot)
                LedgerHolding(ticker: "AAPL", quantity: 50, costBasis: 100),  // $5,000
            ]
        )
        let ctx = DifferentialPrivacy.scopedContext(
            query: "Should I sell TSLA?",
            ledger: ledger,
            profile: techAndBondsProfile(),
            privacyLevel: .moderate
        )
        XCTAssertEqual(ctx.focus?.count, 1, "duplicate lots must collapse to one entry")
        XCTAssertEqual(ctx.focus?.first?.ticker, "TSLA")
        // 5,000 / 10,000 = 50% → concentrated, not the per-lot 25% (large).
        XCTAssertEqual(ctx.focus?.first?.positionSize, "concentrated")
    }

    func testFocusedTickersMatchesHeldWholeWordOnly() {
        let held = [
            LedgerHolding(ticker: "TSLA", quantity: 1, costBasis: 1),
            LedgerHolding(ticker: "V", quantity: 1, costBasis: 1),
        ]
        XCTAssertEqual(DifferentialPrivacy.focusedTickers(in: "sell TSLA now", held: held), ["TSLA"])
        // Whole-word: "V" must not match inside "Value".
        XCTAssertTrue(DifferentialPrivacy.focusedTickers(in: "Value investing tips", held: held).isEmpty)
        XCTAssertEqual(DifferentialPrivacy.focusedTickers(in: "is V a buy?", held: held), ["V"])
        // An unheld symbol pulls in no portfolio data.
        XCTAssertTrue(DifferentialPrivacy.focusedTickers(in: "what about NVDA?", held: held).isEmpty)
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
