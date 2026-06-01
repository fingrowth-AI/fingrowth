import XCTest
@testable import FinGrowth

// Tests for P5-04 — semantic query rewriter.
//
// Acceptance criteria:
//   * 'Should I sell my 500 shares of TSLA bought at $280 given my $50K student
//     loans?' generalizes the share count, cost basis, and debt
//   * 'How is my Fidelity account doing?' drops the brokerage name
//   * A query with no PII passes through unchanged
//   * Substitutions capture each change ({original:'500 shares',
//     replacement:'concentrated position', type:quantity})
//   * Rewriting completes within 3 seconds
//
// Exact LLM phrasing needs the real model; these assert the privacy invariants
// and substitution contract the criteria embody, using the deterministic core.
final class QueryRewriterTests: XCTestCase {

    private let concentratedQuery =
        "Should I sell my 500 shares of TSLA bought at $280 given my $50K student loans?"

    func testGeneralizesCostBasisAndDebtButPreservesShareCount() async {
        // V9-02: tier 3 (cost basis, debt) is generalized at the default level,
        // but the tier-2 share count is preserved.
        let result = await QueryRewriter().rewrite(query: concentratedQuery)

        XCTAssertTrue(result.changed)
        // Tier 3 specifics do not survive.
        for leak in ["$280", "280", "$50K", "50K", "student loans"] {
            XCTAssertFalse(result.rewrittenText.contains(leak), "leaked \(leak): \(result.rewrittenText)")
        }
        // Tier 2 share count IS retained — it describes a portfolio, not a person.
        XCTAssertTrue(result.rewrittenText.contains("500 shares"))
        // Tier 3 changes are captured; tier 2 is NOT substituted.
        XCTAssertFalse(result.substitutions.filter { $0.type == .costBasis }.isEmpty)
        XCTAssertFalse(result.substitutions.filter { $0.type == .liability }.isEmpty)
        XCTAssertTrue(result.substitutions.filter { $0.type == .quantity }.isEmpty)
        XCTAssertGreaterThan(result.confidenceScore, 0)
        XCTAssertLessThanOrEqual(result.confidenceScore, 1)
    }

    func testShareCountAndTickerPreserved() async {
        // AC1: 'Should I sell my 500 TSLA shares?' retains the share count and
        // ticker; with no identity/tier-3 specifics the query is untouched.
        let result = await QueryRewriter().rewrite(query: "Should I sell my 500 shares of TSLA?")
        XCTAssertTrue(result.rewrittenText.contains("500 shares"))
        XCTAssertTrue(result.rewrittenText.contains("TSLA"))
        XCTAssertTrue(result.substitutions.isEmpty)
        XCTAssertFalse(result.changed)
    }

    func testSubstitutionsAreOnlyTier1OrTier3() async {
        // AC4: the substitutions list reflects only tier 1 (and not-opted-in
        // tier 3) removals — never tier 2.
        let ledger = PrivateLedger(
            accountName: "Brokerage",
            accountNumber: "X12345678",
            accountHolder: "John A. Smith"
        )
        let result = await QueryRewriter().rewrite(
            query: "Should I sell my 500 shares of TSLA bought at $280 in my "
                + "Fidelity account X12345678 held by John A. Smith?",
            ledger: ledger
        )
        XCTAssertFalse(result.substitutions.isEmpty)
        for sub in result.substitutions {
            XCTAssertTrue(
                sub.type.tier == .identity || sub.type.tier == .sensitiveFinancial,
                "tier 2 must never be substituted, saw \(sub.type) (\(sub.type.tier))"
            )
        }
        // The tier-2 share count rode through untouched.
        XCTAssertTrue(result.rewrittenText.contains("500 shares"))
    }

    func testTier3PreservedWhenUserOptsIntoDetailed() async {
        // V9-02: tier 3 follows the user setting. At .detailed the user has opted
        // into sharing exact sensitive financials, so cost basis is preserved.
        let query = "Should I sell my 500 shares of TSLA bought at $280?"
        let moderate = await QueryRewriter().rewrite(query: query, privacyLevel: .moderate)
        let detailed = await QueryRewriter().rewrite(query: query, privacyLevel: .detailed)

        XCTAssertFalse(moderate.rewrittenText.contains("$280"))   // generalized by default
        XCTAssertTrue(detailed.rewrittenText.contains("$280"))    // preserved on opt-in
        XCTAssertTrue(detailed.substitutions.isEmpty)
    }

    func testIdentityStrippedEvenWithNoHoldings() async {
        // AC2: a query needing no holdings still strips incidental identity.
        let ledger = PrivateLedger(accountName: "Brokerage", accountNumber: "X12345678")
        let result = await QueryRewriter().rewrite(
            query: "What's the outlook for account X12345678?",
            ledger: ledger
        )
        XCTAssertFalse(result.rewrittenText.contains("X12345678"))
        XCTAssertFalse(result.substitutions.filter { $0.type == .accountNumber }.isEmpty)
    }

    func testFreeformIdentityTokensAreStripped() async {
        // P1 / AC2: typed identity (email, phone, SSN, account number) must be
        // stripped even with no ledger match — while tier 2 survives.
        let query = "Email jane.doe@example.com or call 415-555-0142 re SSN "
            + "123-45-6789 in account X12345678 — should I buy 500 shares of TSLA?"
        let result = await QueryRewriter().rewrite(query: query)  // no ledger

        for leak in ["jane.doe@example.com", "415-555-0142", "123-45-6789", "X12345678"] {
            XCTAssertFalse(result.rewrittenText.contains(leak), "leaked \(leak)")
        }
        // Tier 2 specifics ride through untouched.
        XCTAssertTrue(result.rewrittenText.contains("500 shares"))
        XCTAssertTrue(result.rewrittenText.contains("TSLA"))

        // Every removal is tier 1, and all four identity kinds fired.
        let kinds = Set(result.substitutions.map(\.type))
        XCTAssertTrue(kinds.isSuperset(of: [.email, .phone, .ssn, .accountNumber]))
        for sub in result.substitutions {
            XCTAssertEqual(sub.type.tier, .identity)
        }
    }

    func testParaphraseMustPreserveTier2() {
        // P2: a model paraphrase is accepted only if it keeps the tier-2
        // specifics the deterministic rewrite preserved.
        let deterministic = "How is my portfolio with 500 shares of TSLA doing?"
        // Dropping the share count → rejected.
        XCTAssertFalse(QueryRewriter.preservesTier2("How is my TSLA position doing?", of: deterministic))
        // Dropping the ticker → rejected.
        XCTAssertFalse(QueryRewriter.preservesTier2("How are my 500 shares doing?", of: deterministic))
        // Keeping both → accepted.
        XCTAssertTrue(QueryRewriter.preservesTier2("Is holding 500 shares of TSLA wise?", of: deterministic))
        // A non-ticker acronym (RSI) isn't required, so rewording the metric is fine.
        XCTAssertTrue(QueryRewriter.preservesTier2("What's the relative strength of AAPL?", of: "What is the RSI of AAPL?"))
    }

    func testNeverEmitsLedgerHoldingsNotInQuery() async {
        // AC3: the rewriter scopes to the query — it never dumps the ledger.
        let ledger = PrivateLedger(
            accountName: "Brokerage",
            holdings: [
                LedgerHolding(ticker: "TSLA", quantity: 500, costBasis: 280),
                LedgerHolding(ticker: "AAPL", quantity: 50, costBasis: 150),
            ]
        )
        let result = await QueryRewriter().rewrite(query: "What is the RSI of NVDA?", ledger: ledger)
        // None of the ledger's holdings leak into the rewritten query.
        XCTAssertFalse(result.rewrittenText.contains("TSLA"))
        XCTAssertFalse(result.rewrittenText.contains("AAPL"))
        XCTAssertEqual(result.rewrittenText, "What is the RSI of NVDA?")
    }

    func testBrokerageNameGeneralized() async {
        let result = await QueryRewriter().rewrite(query: "How is my Fidelity account doing?")
        XCTAssertFalse(result.rewrittenText.contains("Fidelity"))
        let brokerage = result.substitutions.first { $0.type == .brokerage }
        XCTAssertEqual(brokerage?.replacement, "portfolio")
        XCTAssertNotNil(brokerage)
    }

    func testNoPIIPassesThroughUnchanged() async {
        let clean = "What is the RSI of AAPL and is it overbought?"
        let result = await QueryRewriter().rewrite(query: clean)
        XCTAssertEqual(result.rewrittenText, clean)
        XCTAssertTrue(result.substitutions.isEmpty)
        XCTAssertEqual(result.confidenceScore, 1.0)
        XCTAssertFalse(result.changed)
    }

    func testLedgerPIIScrubbed() async {
        let ledger = PrivateLedger(
            accountName: "Brokerage",
            accountNumber: "X12345678",
            accountHolder: "John A. Smith"
        )
        let result = await QueryRewriter().rewrite(
            query: "How is account X12345678 held by John A. Smith performing?",
            ledger: ledger
        )
        XCTAssertFalse(result.rewrittenText.contains("X12345678"))
        XCTAssertFalse(result.rewrittenText.contains("John A. Smith"))
        XCTAssertFalse(result.substitutions.filter { $0.type == .accountNumber }.isEmpty)
        XCTAssertFalse(result.substitutions.filter { $0.type == .holderName }.isEmpty)
    }

    func testCompletesQuickly() async {
        let start = Date()
        _ = await QueryRewriter().rewrite(query: concentratedQuery)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testScrubsAllOccurrencesOfLedgerPII() async {
        let ledger = PrivateLedger(accountName: "Brokerage", accountNumber: "X12345678")
        let result = await QueryRewriter().rewrite(
            query: "Compare X12345678 with account X12345678 balance.",
            ledger: ledger
        )
        XCTAssertFalse(result.rewrittenText.contains("X12345678"), "every occurrence must be scrubbed")
    }

    func testSmallShareCountIsPreserved() async {
        // V9-02: share counts are tier 2 and pass through verbatim — no
        // "a position" / "concentrated" generalization, large or small.
        let result = await QueryRewriter().rewrite(query: "Should I trim my 5 shares of AAPL?")
        XCTAssertTrue(result.rewrittenText.contains("5 shares"))
        XCTAssertFalse(result.rewrittenText.contains("concentrated"))
        XCTAssertTrue(result.substitutions.filter { $0.type == .quantity }.isEmpty)
        XCTAssertFalse(result.changed)
    }

    func testPublicMarketDollarFactPassesThrough() async {
        // A non-personal dollar figure must not be scrubbed.
        let clean = "What happened after Apple's $110B buyback?"
        let result = await QueryRewriter().rewrite(query: clean)
        XCTAssertEqual(result.rewrittenText, clean)
        XCTAssertTrue(result.substitutions.isEmpty)
    }

    func testPersonalBalanceIsGeneralized() async {
        let result = await QueryRewriter().rewrite(query: "Is my $250K portfolio too concentrated?")
        XCTAssertFalse(result.rewrittenText.contains("250K"))
        XCTAssertFalse(result.substitutions.filter { $0.type == .amount }.isEmpty)
    }

    func testParaphraseSafetyRejectsResidualSpecifics() async {
        // Build substitutions from the concentrated query, then check the safety
        // gate the way the real-Gemma path would.
        let result = await QueryRewriter().rewrite(query: concentratedQuery)
        let subs = result.substitutions
        // A paraphrase that still contains a stripped number/amount is unsafe …
        XCTAssertFalse(QueryRewriter.isSafe("Should I sell given $280 cost?", substitutions: subs, ledger: nil))
        // … even a partial brokerage leak ("Fidelity portfolio") is caught.
        let brokerage = await QueryRewriter().rewrite(query: "How is my Fidelity account doing?")
        XCTAssertFalse(QueryRewriter.isSafe("How is my Fidelity portfolio doing?", substitutions: brokerage.substitutions, ledger: nil))
        // A clean generalization is safe.
        XCTAssertTrue(QueryRewriter.isSafe("Analyze a concentrated TSLA position for a debt-burdened investor", substitutions: subs, ledger: nil))
    }

    @MainActor
    func testStubGemmaUsesDeterministicResult() async {
        // A stub-backed GemmaService (usesRealModel == false) must not change
        // behavior — the deterministic rewrite still applies.
        let rewriter = QueryRewriter(gemma: GemmaService(backend: StubLlamaBackend(), downloader: nil))
        let result = await rewriter.rewrite(query: concentratedQuery)
        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.substitutions.isEmpty)
        // Tier 3 cost basis is gone; the tier-2 share count is preserved.
        XCTAssertFalse(result.rewrittenText.contains("$280"))
        XCTAssertTrue(result.rewrittenText.contains("500 shares"))
    }
}
