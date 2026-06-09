import Foundation

// Wire models for /api/v1/analysis/query.
// Keep field names mirroring the backend Pydantic schemas (see
// backend/app/models/schemas.py). The JSONEncoder/Decoder used by APIClient
// converts between snake_case on the wire and camelCase here.

enum AnalysisType: String, Codable, Sendable, CaseIterable, Identifiable {
    case fundamental, technical, general
    var id: String { rawValue }
}

// V9-03: a single query-relevant holding, scoped to the question. Tier 2 only
// (ticker + generalized sector + position-size bucket) — never identity, never
// exact value.
struct FocusContext: Codable, Sendable, Equatable, Hashable {
    var ticker: String
    var sector: String
    var positionSize: String
}

struct PortfolioProfile: Codable, Sendable, Equatable, Hashable {
    var sectorWeights: [String: Double] = [:]
    var largestPosition: String?
    var diversification: String?
    var riskOrientation: String?
    // V9-03: populated for a focused (single/specific-ticker) query; nil for a
    // portfolio-level question, which instead carries sectorWeights.
    var focus: [FocusContext]?
}

struct AnalysisQuery: Codable, Sendable, Equatable {
    var query: String
    var ticker: String
    var analysisType: AnalysisType
    var sessionId: UUID?
}

// V7-03: "as of" timestamps for the underlying research data. The backend
// emits ISO-8601 strings (a date for priceAsOf, datetimes for the fetch
// times); we keep them as strings because APIClient's decoder has no custom
// date strategy. `DataFreshness.priceDisplay` formats them for the header.
struct DataFreshness: Codable, Sendable, Equatable {
    var priceAsOf: String?
    var priceFetchedAt: String?
    var newsAsOf: String?
}

struct ResearchData: Codable, Sendable, Equatable {
    var filings: [JSONValue] = []
    var news: [JSONValue] = []
    // Optional, not defaulted: synthesized Decodable ignores property defaults
    // for missing keys, and the partial-research SSE frame omits freshness —
    // an Optional decodes to nil there instead of throwing keyNotFound.
    var freshness: DataFreshness?
}

extension DataFreshness {
    // "as of close 5/28" — derived from the newest price bar's trading day.
    // nil when there is no price data (e.g. a degraded result), so the caller
    // can omit the line entirely.
    var priceDisplay: String? {
        guard let label = Self.shortDate(fromISO: priceAsOf) else { return nil }
        return "as of close \(label)"
    }

    // Format an ISO date/datetime string to a locale-independent "M/d" label.
    // Parsed by hand (not DateFormatter) so the result is deterministic and
    // free of time-zone shifting on a date-only value.
    static func shortDate(fromISO value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let datePart = value.prefix(10)  // tolerate a full datetime prefix
        let parts = datePart.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return "\(month)/\(day)"
    }
}

// One labeled, number-free chunk of the plain-language read ("Momentum", …).
// Produced deterministically by the backend Analyst; the indicator card carries
// the precise values so these never repeat them.
struct InterpretationSection: Codable, Sendable, Equatable, Hashable {
    var label: String
    var body: String
}

struct AnalysisData: Codable, Sendable, Equatable {
    var technical: [String: JSONValue] = [:]
    var narrative: String = ""
    var confidence: String = "insufficient_data"
    // Result-screen redesign: a one-line takeaway and the chunked read.
    var verdict: String = ""
    var interpretation: [InterpretationSection] = []

    init(
        technical: [String: JSONValue] = [:],
        narrative: String = "",
        confidence: String = "insufficient_data",
        verdict: String = "",
        interpretation: [InterpretationSection] = []
    ) {
        self.technical = technical
        self.narrative = narrative
        self.confidence = confidence
        self.verdict = verdict
        self.interpretation = interpretation
    }

    // Custom decode so every field is optional-with-default: the general route
    // and any partial/older payload that omits verdict/interpretation (or even
    // narrative) decode cleanly instead of throwing on a missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        technical = try c.decodeIfPresent([String: JSONValue].self, forKey: .technical) ?? [:]
        narrative = try c.decodeIfPresent(String.self, forKey: .narrative) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? "insufficient_data"
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        interpretation = try c.decodeIfPresent([InterpretationSection].self, forKey: .interpretation) ?? []
    }
}

struct RiskFlag: Codable, Sendable, Equatable, Hashable {
    var code: String
    var detail: String
}

struct RiskReview: Codable, Sendable, Equatable {
    var approved: Bool = true
    var flags: [RiskFlag] = []
    var modifiedResponse: String = ""
    var disclaimer: String = ""
}

struct AnalysisResponse: Codable, Sendable, Equatable {
    var sessionId: UUID
    var ticker: String
    var research: ResearchData
    var analysis: AnalysisData
    var riskReview: RiskReview
    var disclaimer: String
}

// AsyncSequence elements emitted by APIClient.streamAnalysis. Mirrors the SSE
// event sequence documented in backend/app/routers/analysis.py.
enum AnalysisEvent: Sendable, Equatable {
    case progress(stage: String)
    case partialResearch(ResearchData)
    case partialAnalysis(technical: [String: JSONValue], confidence: String)
    case finalResult(AnalysisResponse)
    case serverError(message: String)
}
