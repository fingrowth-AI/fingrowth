import Foundation
import SwiftData

// Device-only privacy audit entry (P5-06). One row per outbound cloud call,
// recording what the user asked, what was actually sent, and what was redacted.
// Stored in SwiftData and NEVER transmitted.
//
// The original generic transmission fields (endpoint/direction/payloadDigest/
// summary) are retained; the privacy fields below were added in schema V6 and
// are optional so pre-V6 rows migrate cleanly.
@Model
final class AuditEntry {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var endpoint: String
    var direction: String
    var payloadDigest: String
    var summary: String

    // P5-06 privacy fields.
    var originalQuery: String?
    var rewrittenQuery: String?
    // JSON-encoded [QuerySubstitution] — what was changed and why.
    var substitutionsJSON: String?
    // Generalization level applied to any shared portfolio context.
    var generalizationLevel: String?
    // JSON-encoded [String] of PII categories detected/redacted.
    var piiDetectedJSON: String?
    var confidenceScore: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        endpoint: String,
        direction: String,
        payloadDigest: String,
        summary: String = "",
        originalQuery: String? = nil,
        rewrittenQuery: String? = nil,
        substitutionsJSON: String? = nil,
        generalizationLevel: String? = nil,
        piiDetectedJSON: String? = nil,
        confidenceScore: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.direction = direction
        self.payloadDigest = payloadDigest
        self.summary = summary
        self.originalQuery = originalQuery
        self.rewrittenQuery = rewrittenQuery
        self.substitutionsJSON = substitutionsJSON
        self.generalizationLevel = generalizationLevel
        self.piiDetectedJSON = piiDetectedJSON
        self.confidenceScore = confidenceScore
    }

    // Decoded substitutions for display.
    var substitutions: [QuerySubstitution] {
        guard let json = substitutionsJSON, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QuerySubstitution].self, from: data)) ?? []
    }

    var piiDetected: [String] {
        guard let json = piiDetectedJSON, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // True when this row records a privacy-relevant outbound query (vs. a
    // generic transmission log).
    var isPrivacyEntry: Bool { originalQuery != nil }
}
