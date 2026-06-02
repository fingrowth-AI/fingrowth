import CryptoKit
import Foundation
import SwiftData

// Privacy Audit Log (P5-06).
//
// Records one device-only AuditEntry every time a query is prepared for the
// cloud: the original text, what was actually sent, the rewriting
// substitutions, the generalization level, the PII categories detected, and
// the confidence score. Stored in SwiftData and never transmitted — the
// service has no network surface at all. The user reviews it in the Privacy
// tab and can export it as JSON for their own records.
@MainActor
final class PrivacyAuditLog {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // Throws if the entry can't be durably persisted — a swallowed save would
    // let callers believe the cloud call was logged when it wasn't.
    @discardableResult
    func record(
        original: String,
        rewritten: String,
        profile: GeneralizedProfile?,
        substitutions: [QuerySubstitution],
        confidence: Double = 1.0,
        endpoint: String = "/api/v1/analysis/query"
    ) throws -> AuditEntry {
        // PII categories detected = the distinct substitution types, in a
        // stable order for display.
        let piiDetected = orderedUniqueTypes(substitutions)

        // V9-03: the outbound payload is the rewritten query *and* the scoped
        // portfolio profile. Digest both so the log attests to everything that
        // leaves the device — not just the query text — and describe the shared
        // context in the summary so the user can see what portfolio data went
        // out (Tier 2 only; identity never reaches here).
        let profileJSON = profile.flatMap(Self.canonicalProfileJSON)
        let payload = profileJSON.map { "\(rewritten)\u{1e}\($0)" } ?? rewritten
        let redaction = substitutions.isEmpty
            ? "No PII detected"
            : "\(substitutions.count) item(s) redacted"
        let summary = Self.contextSummary(profile).map { "\(redaction); \($0)" } ?? redaction

        let entry = AuditEntry(
            endpoint: endpoint,
            direction: "outbound",
            payloadDigest: Self.sha256(payload),
            summary: summary,
            originalQuery: original,
            rewrittenQuery: rewritten,
            substitutionsJSON: Self.encode(substitutions),
            generalizationLevel: profile?.privacyLevel.rawValue,
            piiDetectedJSON: Self.encode(piiDetected),
            confidenceScore: confidence
        )
        context.insert(entry)
        do {
            try context.save()
        } catch {
            context.delete(entry)  // don't leave a half-recorded row in memory
            throw error
        }
        return entry
    }

    /// All audit entries, newest first, encoded as JSON for user export. This
    /// is the only thing that ever leaves the log — and only at the user's
    /// explicit request (e.g. a share sheet), never over the network.
    func exportJSON() throws -> Data {
        let descriptor = FetchDescriptor<AuditEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let entries = try context.fetch(descriptor)
        let dtos = entries.map(ExportedAuditEntry.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(dtos)
    }

    private func orderedUniqueTypes(_ substitutions: [QuerySubstitution]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for sub in substitutions where seen.insert(sub.type.rawValue).inserted {
            ordered.append(sub.type.rawValue)
        }
        return ordered
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Canonical (sorted-key) JSON of the shared profile so the same context
    // always digests identically. This is the portfolio half of the outbound
    // payload (V9-03).
    private static func canonicalProfileJSON(_ profile: GeneralizedProfile) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profile) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // A human-readable description of the portfolio context shared with the
    // cloud, for the Privacy tab. Tier 2 only: focus tickers or "sector weights".
    private static func contextSummary(_ profile: GeneralizedProfile?) -> String? {
        guard let profile else { return nil }
        if let focus = profile.focus, !focus.isEmpty {
            return "shared context: holdings " + focus.map(\.ticker).joined(separator: ", ")
        }
        if !profile.sectorWeights.isEmpty {
            return "shared context: sector weights"
        }
        return "shared context: portfolio profile"
    }

    private static func sha256(_ text: String) -> String {
        // A real, stable cryptographic digest of the transmitted payload — so
        // the log can attest to exactly what was sent and the same text always
        // hashes identically (Swift's Hasher is non-cryptographic and
        // process-seeded, so it can't).
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// Codable projection of an AuditEntry for export.
private struct ExportedAuditEntry: Encodable {
    let id: UUID
    let timestamp: Date
    let originalQuery: String?
    let rewrittenQuery: String?
    let substitutions: [QuerySubstitution]
    let generalizationLevel: String?
    let piiDetected: [String]
    let confidenceScore: Double?
    let endpoint: String

    init(_ entry: AuditEntry) {
        self.id = entry.id
        self.timestamp = entry.timestamp
        self.originalQuery = entry.originalQuery
        self.rewrittenQuery = entry.rewrittenQuery
        self.substitutions = entry.substitutions
        self.generalizationLevel = entry.generalizationLevel
        self.piiDetected = entry.piiDetected
        self.confidenceScore = entry.confidenceScore
        self.endpoint = entry.endpoint
    }
}
