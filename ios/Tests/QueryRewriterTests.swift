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

    func testGeneralizesQuantityCostBasisAndDebt() async {
        let result = await QueryRewriter().rewrite(query: concentratedQuery)

        XCTAssertTrue(result.changed)
        // No private specifics survive.
        for leak in ["500", "$280", "280", "$50K", "50K", "student loans"] {
            XCTAssertFalse(result.rewrittenText.contains(leak), "leaked \(leak): \(result.rewrittenText)")
        }
        // Each kind of change is captured.
        XCTAssertFalse(result.substitutions.filter { $0.type == .quantity }.isEmpty)
        XCTAssertFalse(result.substitutions.filter { $0.type == .costBasis }.isEmpty)
        XCTAssertFalse(result.substitutions.filter { $0.type == .liability }.isEmpty)
        XCTAssertGreaterThan(result.confidenceScore, 0)
        XCTAssertLessThanOrEqual(result.confidenceScore, 1)
    }

    func testSubstitutionContractForQuantity() async {
        let result = await QueryRewriter().rewrite(query: concentratedQuery)
        let quantity = result.substitutions.first { $0.type == .quantity }
        XCTAssertEqual(quantity?.original, "500 shares")
        XCTAssertEqual(quantity?.replacement, "concentrated position")
        XCTAssertEqual(quantity?.type, .quantity)
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

    func testSmallShareCountIsNotConcentrated() async {
        let result = await QueryRewriter().rewrite(query: "Should I trim my 5 shares of AAPL?")
        let quantity = result.substitutions.first { $0.type == .quantity }
        XCTAssertEqual(quantity?.replacement, "a position")
        XCTAssertFalse(result.rewrittenText.contains("concentrated"))
        XCTAssertFalse(result.rewrittenText.contains("5 shares"))
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
        XCTAssertFalse(result.rewrittenText.contains("500"))
    }
}
