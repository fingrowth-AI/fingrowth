import XCTest
import SwiftData
@testable import FinGrowth

// Tests for P4-05 — heuristic CSV brokerage import.
//
// Acceptance criteria from the design doc:
//   * Importing a Fidelity CSV populates PrivateLedger correctly
//   * ShareableProfile contains sector weights summing to 100%
//   * Unknown CSV format shows helpful error, not crash
//   * PrivateLedger data is encrypted at rest via SwiftData
//
// The encryption criterion is fulfilled by AppDataLocation applying
// .completeUnlessOpen file protection to the SwiftData store; the round
// trip test below confirms the parser output survives that store.

final class CSVPrivacyParserTests: XCTestCase {

    // MARK: - Fidelity

    func testFidelityCSVPopulatesLedgerAndProfile() throws {
        let csv = """
        Account Number,Account Name,Symbol,Description,Quantity,Last Price,Current Value,Average Cost Basis,Cost Basis Total
        X12345678,INDIVIDUAL,AAPL,APPLE INC,10,$190.00,$1900.00,$150.00,$1500.00
        X12345678,INDIVIDUAL,MSFT,MICROSOFT CORP,5,$420.00,$2100.00,$300.00,$1500.00
        X12345678,INDIVIDUAL,JPM,JPMORGAN CHASE,8,$200.00,$1600.00,$160.00,$1280.00
        """

        let result = try CSVPrivacyParser.parse(csv: csv)

        XCTAssertEqual(result.format, .fidelity)
        XCTAssertEqual(result.ledger.holdings.count, 3)

        let byTicker = Dictionary(uniqueKeysWithValues: result.ledger.holdings.map { ($0.ticker, $0) })
        XCTAssertEqual(byTicker["AAPL"]?.quantity, 10)
        XCTAssertEqual(byTicker["AAPL"]?.costBasis, 150.0)
        XCTAssertEqual(byTicker["MSFT"]?.quantity, 5)
        XCTAssertEqual(byTicker["MSFT"]?.costBasis, 300.0)
        XCTAssertEqual(byTicker["JPM"]?.quantity, 8)

        XCTAssertFalse(result.ledger.rawCSVDigest.isEmpty, "Digest preserves a fingerprint of the source CSV without storing it")
    }

    func testFidelityWithOnlyTotalCostBasisDerivesPerShare() throws {
        // Some Fidelity exports drop the per-share "Average Cost Basis" column
        // and only ship the total. Parser should divide the total by quantity.
        let csv = """
        Account Number,Account Name,Symbol,Quantity,Cost Basis Total
        X1,IRA,NVDA,4,$2000.00
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        XCTAssertEqual(result.format, .fidelity)
        XCTAssertEqual(result.ledger.holdings.first?.costBasis, 500.0)
    }

    // MARK: - Schwab

    func testSchwabCSVUsingTotalCostBasis() throws {
        // Schwab quotes every field — exercises the quote-stripping tokenizer.
        let csv = """
        "Symbol","Description","Quantity","Price","Market Value","Cost Basis","Security Type"
        "AAPL","APPLE INC","10","$190.00","$1900.00","$1500.00","Equity"
        "GOOGL","ALPHABET INC","2","$140.00","$280.00","$200.00","Equity"
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        XCTAssertEqual(result.format, .schwab)
        let byTicker = Dictionary(uniqueKeysWithValues: result.ledger.holdings.map { ($0.ticker, $0) })
        XCTAssertEqual(byTicker["AAPL"]?.costBasis, 150.0)
        XCTAssertEqual(byTicker["GOOGL"]?.quantity, 2)
        XCTAssertEqual(byTicker["GOOGL"]?.costBasis, 100.0)
    }

    // MARK: - Robinhood

    func testRobinhoodCSVUsesAverageCostPerShare() throws {
        let csv = """
        Symbol,Name,Quantity,Average Cost,Equity
        TSLA,Tesla Inc,3,210.50,720.00
        AMD,Advanced Micro Devices,12,95.25,1300.00
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        XCTAssertEqual(result.format, .robinhood)
        XCTAssertEqual(result.ledger.holdings.count, 2)
        let byTicker = Dictionary(uniqueKeysWithValues: result.ledger.holdings.map { ($0.ticker, $0) })
        XCTAssertEqual(byTicker["TSLA"]?.costBasis, 210.50)
        XCTAssertEqual(byTicker["AMD"]?.quantity, 12)
    }

    // MARK: - Richer ledger fields (design §8.1 Holding)

    func testFidelityCSVCapturesAccountTypeAndPurchaseDate() throws {
        // Fidelity exports that ship Account Type + Date Acquired should land
        // in the device-only PrivateLedger, and the brokerage source should be
        // stamped on the ledger.
        let csv = """
        Account Number,Account Name,Account Type,Symbol,Quantity,Average Cost Basis,Date Acquired
        X1,INDIVIDUAL,Roth IRA,AAPL,10,150,2023-06-15
        X1,INDIVIDUAL,Roth IRA,MSFT,5,300,03/02/2022
        """
        let result = try CSVPrivacyParser.parse(csv: csv)

        XCTAssertEqual(result.format, .fidelity)
        XCTAssertEqual(result.ledger.sourceBrokerage, "Fidelity")

        let byTicker = Dictionary(uniqueKeysWithValues: result.ledger.holdings.map { ($0.ticker, $0) })
        XCTAssertEqual(byTicker["AAPL"]?.accountType, "Roth IRA")
        XCTAssertEqual(byTicker["MSFT"]?.accountType, "Roth IRA")

        // The parser anchors dates to UTC midnight; reconstruct independently.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expectedAAPL = utc.date(from: DateComponents(year: 2023, month: 6, day: 15))
        XCTAssertEqual(byTicker["AAPL"]?.purchaseDate, expectedAAPL)
        XCTAssertNotNil(byTicker["MSFT"]?.purchaseDate, "M/d/yyyy layout should parse too")
    }

    func testHoldingsWithoutOptionalColumnsLeaveFieldsNil() throws {
        let csv = """
        Symbol,Quantity,Average Cost
        AMD,3,95
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        let holding = try XCTUnwrap(result.ledger.holdings.first)
        XCTAssertNil(holding.accountType)
        XCTAssertNil(holding.purchaseDate)
        XCTAssertEqual(result.ledger.sourceBrokerage, "Robinhood")
    }

    // MARK: - ShareableProfile invariants

    func testShareableProfileSectorWeightsSumTo100() throws {
        let csv = """
        Account Number,Account Name,Symbol,Quantity,Average Cost Basis
        X1,IRA,AAPL,10,150
        X1,IRA,MSFT,5,300
        X1,IRA,JPM,8,160
        X1,IRA,JNJ,4,165
        X1,IRA,XOM,7,110
        X1,IRA,AMZN,3,140
        X1,IRA,ZZZZ,5,80
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        let weights = try XCTUnwrap(decodeWeights(result.profile.sectorWeightsJSON))
        let sum = weights.values.reduce(0, +)
        XCTAssertEqual(sum, 100.0, accuracy: 0.01, "Sector weights must sum to exactly 100%")
        XCTAssertTrue(weights.keys.contains("Other"), "Unknown tickers fall into the Other bucket")
        XCTAssertTrue(weights.values.allSatisfy { $0 >= 0 }, "No negative sector weights")
    }

    func testShareableProfileValueBucketAndRiskScore() throws {
        // Concentrated single-stock portfolio — risk score should be 1.0.
        let csv = """
        Symbol,Quantity,Average Cost
        TSLA,100,200
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        XCTAssertEqual(result.profile.totalValueBucket, "10k-50k")
        XCTAssertEqual(result.profile.riskScore, 1.0, accuracy: 0.001)
    }

    func testValueBucketGeneralization() {
        XCTAssertEqual(ValueBucket.bucket(for: 0), "<10k")
        XCTAssertEqual(ValueBucket.bucket(for: 9_999), "<10k")
        XCTAssertEqual(ValueBucket.bucket(for: 10_000), "10k-50k")
        XCTAssertEqual(ValueBucket.bucket(for: 49_999), "10k-50k")
        XCTAssertEqual(ValueBucket.bucket(for: 50_000), "50k-250k")
        XCTAssertEqual(ValueBucket.bucket(for: 250_000), "250k-1M")
        XCTAssertEqual(ValueBucket.bucket(for: 2_500_000), "1M+")
    }

    // MARK: - Unknown format / error handling

    func testUnknownCSVFormatReturnsHelpfulError() {
        let csv = """
        first_name,last_name,birthday
        Ada,Lovelace,1815-12-10
        """
        XCTAssertThrowsError(try CSVPrivacyParser.parse(csv: csv)) { error in
            guard let parserError = error as? CSVParserError else {
                return XCTFail("Expected CSVParserError, got \(error)")
            }
            switch parserError {
            case .unrecognizedFormat(let preview):
                XCTAssertTrue(preview.contains("first_name"))
                XCTAssertTrue(
                    parserError.errorDescription?.contains("Fidelity") ?? false,
                    "Error message should list supported brokerages"
                )
            default:
                XCTFail("Expected .unrecognizedFormat, got \(parserError)")
            }
        }
    }

    func testEmptyCSVThrowsEmptyError() {
        XCTAssertThrowsError(try CSVPrivacyParser.parse(csv: "   \n\n")) { error in
            XCTAssertEqual(error as? CSVParserError, .empty)
        }
    }

    func testFidelityHeadersWithNoDataRowsThrowsNoValidRows() {
        let csv = "Account Number,Account Name,Symbol,Quantity,Average Cost Basis\n"
        XCTAssertThrowsError(try CSVPrivacyParser.parse(csv: csv)) { error in
            XCTAssertEqual(error as? CSVParserError, .noValidRows)
        }
    }

    func testRowsWithMissingOrInvalidFieldsAreSkipped() throws {
        // Mix of valid and corrupt rows: blank symbol, zero quantity,
        // missing cost. Parser should skip the bad rows and import the good.
        let csv = """
        Symbol,Quantity,Average Cost
        AAPL,10,150
        ,5,100
        MSFT,0,300
        TSLA,2,
        AMD,3,95
        """
        let result = try CSVPrivacyParser.parse(csv: csv)
        let tickers = Set(result.ledger.holdings.map(\.ticker))
        XCTAssertEqual(tickers, ["AAPL", "AMD"])
    }

    // MARK: - SwiftData round-trip (encryption-at-rest path)

    // PrivateLedger encryption is delivered by AppDataLocation's
    // .completeUnlessOpen file-protection class applied in
    // AppContainer.makeContainer. This test confirms the parser output
    // round-trips through that same container.
    func testParsedLedgerRoundTripsThroughSwiftDataContainer() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appending(path: "csvimport.sqlite")

        let csv = """
        Symbol,Quantity,Average Cost
        AAPL,4,150
        MSFT,2,300
        """
        let result = try CSVPrivacyParser.parse(csv: csv)

        let container = try AppContainer.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.insert(result.ledger)
        context.insert(result.profile)
        try context.save()

        let reopened = try AppContainer.makeContainer(storeURL: storeURL)
        let readContext = ModelContext(reopened)
        let ledgers = try readContext.fetch(FetchDescriptor<PrivateLedger>())
        XCTAssertEqual(ledgers.count, 1)
        XCTAssertEqual(ledgers.first?.holdings.count, 2)
        let profiles = try readContext.fetch(FetchDescriptor<ShareableProfile>())
        XCTAssertEqual(profiles.count, 1)
        XCTAssertFalse(profiles.first?.sectorWeightsJSON.isEmpty ?? true)
    }

    // MARK: - Helpers

    private func decodeWeights(_ json: String) -> [String: Double]? {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return nil }
        return dict.compactMapValues { value in
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let n = value as? NSNumber { return n.doubleValue }
            return nil
        }
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "CSVPrivacyParserTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
