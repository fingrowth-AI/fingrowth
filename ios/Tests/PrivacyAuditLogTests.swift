import XCTest
import SwiftData
import CryptoKit
@testable import FinGrowth

// Tests for P5-06 — Privacy Audit Log.
//
// Acceptance criteria:
//   * Every cloud API call creates exactly one AuditEntry
//   * PII-containing query records the redacted items
//   * Entries are reverse chronological
//   * Detail data exposes original vs. rewritten + substitutions
//   * Log can be exported as JSON
//   * Audit log is device-only (SwiftData; never transmitted)
@MainActor
final class PrivacyAuditLogTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "PrivacyAuditLogTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let container = try AppContainer.makeContainer(storeURL: dir.appending(path: "audit.sqlite"))
        return ModelContext(container)
    }

    private let subs = [
        QuerySubstitution(original: "500 shares", replacement: "concentrated position", type: .quantity),
        QuerySubstitution(original: "$50K student loans", replacement: "significant debt obligations", type: .liability),
    ]

    func testRecordCreatesExactlyOneEntry() throws {
        let context = try makeContext()
        let log = PrivacyAuditLog(context: context)

        try log.record(
            original: "Should I sell my 500 shares given my $50K student loans?",
            rewritten: "Should I sell my concentrated position given my significant debt obligations?",
            profile: nil,
            substitutions: subs,
            confidence: 0.75
        )

        let entries = try context.fetch(FetchDescriptor<AuditEntry>())
        XCTAssertEqual(entries.count, 1, "one record → exactly one AuditEntry")
    }

    func testRecordCapturesSubstitutionsAndPII() throws {
        let context = try makeContext()
        let entry = try PrivacyAuditLog(context: context).record(
            original: "Should I sell my 500 shares given my $50K student loans?",
            rewritten: "Should I sell my concentrated position given my significant debt obligations?",
            profile: nil,
            substitutions: subs,
            confidence: 0.75
        )

        XCTAssertEqual(entry.substitutions.count, 2)
        XCTAssertEqual(entry.substitutions.first?.original, "500 shares")
        XCTAssertEqual(Set(entry.piiDetected), ["quantity", "liability"])
        XCTAssertEqual(entry.confidenceScore, 0.75)
        XCTAssertTrue(entry.isPrivacyEntry)
        XCTAssertFalse(entry.rewrittenQuery?.contains("500") ?? true)
    }

    func testNoPIIRecordHasEmptySubstitutions() throws {
        let context = try makeContext()
        let entry = try PrivacyAuditLog(context: context).record(
            original: "What is the RSI of AAPL?",
            rewritten: "What is the RSI of AAPL?",
            profile: nil,
            substitutions: [],
            confidence: 1.0
        )
        XCTAssertTrue(entry.substitutions.isEmpty)
        XCTAssertTrue(entry.piiDetected.isEmpty)
        XCTAssertEqual(entry.summary, "No PII detected")
    }

    func testGeneralizationLevelRecorded() throws {
        let context = try makeContext()
        let profile = GeneralizedProfile(
            privacyLevel: .moderate, sectorWeights: ["tech": 100],
            largestPosition: "concentrated", diversification: "low",
            riskScore: nil, valueBucket: nil
        )
        let entry = try PrivacyAuditLog(context: context).record(
            original: "q", rewritten: "q", profile: profile, substitutions: [], confidence: 1
        )
        XCTAssertEqual(entry.generalizationLevel, "moderate")
    }

    func testPayloadDigestIsStableSHA256OfSentText() throws {
        let context = try makeContext()
        let sent = "Should I sell my concentrated position?"
        let entry = try PrivacyAuditLog(context: context).record(
            original: "Should I sell my 500 shares?", rewritten: sent,
            profile: nil, substitutions: subs, confidence: 0.75
        )
        // A real SHA-256 of the transmitted text: stable + attestable.
        let expected = SHA256.hash(data: Data(sent.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(entry.payloadDigest, expected)
        XCTAssertEqual(entry.payloadDigest.count, 64)
    }

    func testPayloadDigestCoversPortfolioProfileAndSummaryShowsContext() throws {
        // V9-03: the audit must attest to the *whole* outbound payload, not just
        // the query — otherwise it couldn't verify what portfolio context was sent.
        let context = try makeContext()
        let log = PrivacyAuditLog(context: context)
        let sent = "How are my 500 shares of TSLA doing?"

        func focusProfile(ticker: String) -> GeneralizedProfile {
            GeneralizedProfile(
                privacyLevel: .moderate, sectorWeights: [:], largestPosition: nil,
                diversification: "low", riskScore: nil, valueBucket: nil,
                focus: [FocusContext(ticker: ticker, sector: "consumer_discretionary",
                                     positionSize: "concentrated")]
            )
        }

        let queryOnly = try log.record(original: "o", rewritten: sent, profile: nil, substitutions: [])
        let withTSLA = try log.record(original: "o", rewritten: sent, profile: focusProfile(ticker: "TSLA"), substitutions: [])
        let withNVDA = try log.record(original: "o", rewritten: sent, profile: focusProfile(ticker: "NVDA"), substitutions: [])

        // Same query text, but the digest now changes with the profile — proof
        // it covers the portfolio payload, not just the query.
        XCTAssertNotEqual(queryOnly.payloadDigest, withTSLA.payloadDigest)
        XCTAssertNotEqual(withTSLA.payloadDigest, withNVDA.payloadDigest)
        // And the user can see which holding's context was shared.
        XCTAssertTrue(withTSLA.summary.contains("TSLA"))
    }

    func testEntriesAreReverseChronological() throws {
        let context = try makeContext()
        // Insert with explicit timestamps (mirrors the Privacy tab's @Query sort).
        let base = Date()
        for (offset, label) in ["oldest", "middle", "newest"].enumerated() {
            context.insert(AuditEntry(
                timestamp: base.addingTimeInterval(Double(offset)),
                endpoint: "/api/v1/analysis/query",
                direction: "outbound",
                payloadDigest: "d",
                originalQuery: label
            ))
        }
        try context.save()

        let descriptor = FetchDescriptor<AuditEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        let ordered = try context.fetch(descriptor).map(\.originalQuery)
        XCTAssertEqual(ordered, ["newest", "middle", "oldest"])
    }

    func testExportJSONRoundTrips() throws {
        let context = try makeContext()
        let log = PrivacyAuditLog(context: context)
        try log.record(original: "orig A", rewritten: "rw A", profile: nil, substitutions: subs, confidence: 0.75)
        try log.record(original: "orig B", rewritten: "rw B", profile: nil, substitutions: [], confidence: 1.0)

        let data = try log.exportJSON()
        struct Exported: Decodable {
            let originalQuery: String?
            let rewrittenQuery: String?
            let substitutions: [QuerySubstitution]
            let piiDetected: [String]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([Exported].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(Set(decoded.compactMap(\.originalQuery)), ["orig A", "orig B"])
        let withSubs = decoded.first { !$0.substitutions.isEmpty }
        XCTAssertEqual(withSubs?.substitutions.first?.replacement, "concentrated position")
    }
}
