import XCTest
@testable import FinGrowth

// Tests for P5-03 — Gemma-powered CSV privacy parser.
//
// Acceptance criteria:
//   * Account number in a Fidelity header lands in PrivateLedger, not Profile
//   * Holder name 'John A. Smith' detected in PIIReport with confidence > 0.9
//   * ShareableProfile contains only anonymized fields (no PII)
//   * Pipeline runs with zero network calls
//   * Completes within 10 seconds for a 500-row CSV
//   * Supports >= 5 brokerage formats (Fidelity/Schwab/Robinhood/Vanguard/E*TRADE)
//
// All tests use the heuristic detector (gemma == nil) or the stub-backed
// GemmaService, so they run entirely offline and deterministically.
final class CSVPrivacyParserGemmaTests: XCTestCase {

    private let fidelityWithPII = """
    Account Number,Account Name,Account Holder,Symbol,Quantity,Average Cost Basis
    X12345678,INDIVIDUAL,John A. Smith,AAPL,10,150
    X12345678,INDIVIDUAL,John A. Smith,MSFT,5,300
    """

    // MARK: - PII separation

    func testAccountNumberStaysInLedgerNotProfile() async throws {
        let result = try await CSVPrivacyParser.parse(csvData: fidelityWithPII)

        XCTAssertEqual(result.format, .fidelity)
        XCTAssertEqual(result.ledger.accountNumber, "X12345678")
        XCTAssertEqual(result.ledger.accountHolder, "John A. Smith")

        // The account number must not appear anywhere in the shareable profile.
        XCTAssertFalse(profileBlob(result.profile).contains("X12345678"))
        XCTAssertFalse(profileBlob(result.profile).contains("John"))
    }

    func testHolderNameDetectedWithHighConfidence() async throws {
        let result = try await CSVPrivacyParser.parse(csvData: fidelityWithPII)

        let names = result.piiReport.findings(of: .holderName)
        let finding = try XCTUnwrap(names.first)
        XCTAssertGreaterThan(finding.confidence, 0.9)
        XCTAssertNotEqual(finding.maskedValue, "John A. Smith", "report must not expose the full name")
    }

    func testAccountNumberDetectedInReport() async throws {
        let result = try await CSVPrivacyParser.parse(csvData: fidelityWithPII)
        let accounts = result.piiReport.findings(of: .accountNumber)
        let finding = try XCTUnwrap(accounts.first)
        XCTAssertGreaterThan(finding.confidence, 0.9)
        XCTAssertFalse(finding.maskedValue.contains("12345678"), "account number must be masked")
    }

    func testShareableProfileContainsOnlyAnonymizedFields() async throws {
        let result = try await CSVPrivacyParser.parse(csvData: fidelityWithPII)
        let blob = profileBlob(result.profile)
        // No raw PII, no raw holdings identifiers beyond generalized sectors.
        for leak in ["X12345678", "John", "Smith"] {
            XCTAssertFalse(blob.contains(leak), "profile leaked \(leak)")
        }
        // The anonymized fields are present and well-formed.
        XCTAssertFalse(result.profile.sectorWeightsJSON.isEmpty)
        XCTAssertFalse(result.profile.totalValueBucket.isEmpty)
    }

    // MARK: - SSN detection by value pattern

    func testSSNDetectedByPattern() async throws {
        let csv = """
        Account Number,Tax ID,Symbol,Quantity,Average Cost Basis
        X1,123-45-6789,AAPL,10,150
        """
        let result = try await CSVPrivacyParser.parse(csvData: csv)
        let ssns = result.piiReport.findings(of: .ssn)
        XCTAssertGreaterThan(try XCTUnwrap(ssns.first).confidence, 0.9)
    }

    // MARK: - Metadata above the table

    func testHolderNameInMetadataAboveHeaderIsDetected() async throws {
        // Brokerage exports often put account metadata above the holdings table.
        let csv = """
        Account Holder,John A. Smith
        Account Number,X12345678

        Symbol,Quantity,Cost Basis,Security Type
        AAPL,10,1500,Equity
        """
        let result = try await CSVPrivacyParser.parse(csvData: csv)

        XCTAssertEqual(result.format, .schwab)  // resolved past the metadata rows
        let names = result.piiReport.findings(of: .holderName)
        XCTAssertGreaterThan(try XCTUnwrap(names.first).confidence, 0.9)
        // Metadata identity must reach the device-only ledger.
        XCTAssertEqual(result.ledger.accountHolder, "John A. Smith")
        XCTAssertEqual(result.ledger.accountNumber, "X12345678")
        XCTAssertFalse(profileBlob(result.profile).contains("Smith"))
    }

    // MARK: - Masking

    func testShortValuesAreFullyMasked() {
        // "Last 4" must not expose the whole value for short inputs.
        XCTAssertEqual(HeuristicPIIExtractor.mask("X1", kind: .accountNumber), "••")
        XCTAssertEqual(HeuristicPIIExtractor.mask("1234", kind: .accountNumber), "••••")
        XCTAssertFalse(HeuristicPIIExtractor.mask("X1", kind: .accountNumber).contains("X"))
        // Long values still reveal only the last 4.
        XCTAssertEqual(HeuristicPIIExtractor.mask("12345678", kind: .accountNumber), "••••5678")
    }

    // MARK: - Format coverage (>= 5)

    func testVanguardFormatDetected() async throws {
        let csv = """
        Account Number,Investment Name,Symbol,Shares,Cost Basis
        99887766,VANGUARD TOTAL STOCK,VTI,10,2000
        """
        let result = try await CSVPrivacyParser.parse(csvData: csv)
        XCTAssertEqual(result.format, .vanguard)
        XCTAssertEqual(result.ledger.holdings.first?.costBasis, 200, "total cost / shares")
        XCTAssertEqual(result.ledger.accountNumber, "99887766")
    }

    func testEtradeFormatDetected() async throws {
        let csv = """
        Symbol,Quantity,Price Paid,Last Price
        AAPL,10,150,190
        """
        let result = try await CSVPrivacyParser.parse(csvData: csv)
        XCTAssertEqual(result.format, .etrade)
        XCTAssertEqual(result.ledger.holdings.first?.costBasis, 150, "per-share price paid")
    }

    // MARK: - Gemma stub falls back to heuristic

    @MainActor
    func testStubBackedGemmaFallsBackToHeuristicDetection() async throws {
        // A GemmaService on the dev stub (usesRealModel == false) must still
        // produce PII findings via the heuristic fallback.
        let gemma = GemmaService(backend: StubLlamaBackend(), downloader: nil)
        let result = try await CSVPrivacyParser.parse(csvData: fidelityWithPII, gemma: gemma)
        XCTAssertFalse(result.piiReport.findings(of: .holderName).isEmpty)
        XCTAssertEqual(result.ledger.accountNumber, "X12345678")
    }

    // MARK: - Performance (offline, 500 rows < 10s)

    func testParsesLargeCSVQuickly() async throws {
        var lines = ["Account Number,Account Holder,Symbol,Quantity,Average Cost Basis"]
        let tickers = ["AAPL", "MSFT", "GOOGL", "AMZN", "TSLA"]
        for i in 0..<500 {
            lines.append("X\(i),John A. Smith,\(tickers[i % tickers.count]),\(i % 50 + 1),\(100 + i % 200)")
        }
        let csv = lines.joined(separator: "\n")

        let start = Date()
        let result = try await CSVPrivacyParser.parse(csvData: csv)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 10, "500-row parse must finish within 10s")
        XCTAssertEqual(result.ledger.holdings.count, 500)
    }

    // MARK: - Helpers

    // Everything in the shareable profile, concatenated, to scan for leaks.
    private func profileBlob(_ profile: ShareableProfile) -> String {
        [profile.totalValueBucket, profile.sectorWeightsJSON, String(profile.riskScore)]
            .joined(separator: "|")
    }
}
