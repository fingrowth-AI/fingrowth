import Foundation
import SwiftData

// Persisted record of a completed research run. Lives in the SwiftData store
// alongside PrivateLedger / ShareableProfile so prior analyses survive app
// restarts (P4-03 acceptance: "Results persist in SwiftData history").
//
// Indicators and risk flags are serialized as JSON blobs to avoid an explosion
// of relationship tables for what is effectively dynamic LLM output.
@Model
final class ResearchHistoryEntry {
    var createdAt: Date
    var ticker: String
    var query: String
    var analysisTypeRaw: String
    var narrative: String
    var confidence: String
    var disclaimer: String
    var indicatorsJSON: Data
    var riskFlagsJSON: Data
    var riskApproved: Bool
    var riskModifiedResponse: String

    init(
        createdAt: Date,
        ticker: String,
        query: String,
        analysisType: AnalysisType,
        narrative: String,
        confidence: String,
        disclaimer: String,
        indicatorsJSON: Data,
        riskFlagsJSON: Data,
        riskApproved: Bool,
        riskModifiedResponse: String
    ) {
        self.createdAt = createdAt
        self.ticker = ticker
        self.query = query
        self.analysisTypeRaw = analysisType.rawValue
        self.narrative = narrative
        self.confidence = confidence
        self.disclaimer = disclaimer
        self.indicatorsJSON = indicatorsJSON
        self.riskFlagsJSON = riskFlagsJSON
        self.riskApproved = riskApproved
        self.riskModifiedResponse = riskModifiedResponse
    }

    var analysisType: AnalysisType {
        AnalysisType(rawValue: analysisTypeRaw) ?? .general
    }

    var indicators: [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: indicatorsJSON)) ?? [:]
    }

    var riskFlags: [RiskFlag] {
        (try? JSONDecoder().decode([RiskFlag].self, from: riskFlagsJSON)) ?? []
    }
}

extension ResearchHistoryEntry {
    static func from(query: AnalysisQuery, response: AnalysisResponse, now: Date = Date()) -> ResearchHistoryEntry {
        let encoder = JSONEncoder()
        let indicators = (try? encoder.encode(response.analysis.technical)) ?? Data("{}".utf8)
        let flags = (try? encoder.encode(response.riskReview.flags)) ?? Data("[]".utf8)
        return ResearchHistoryEntry(
            createdAt: now,
            ticker: response.ticker,
            query: query.query,
            analysisType: query.analysisType,
            narrative: response.analysis.narrative,
            confidence: response.analysis.confidence,
            disclaimer: response.disclaimer,
            indicatorsJSON: indicators,
            riskFlagsJSON: flags,
            riskApproved: response.riskReview.approved,
            riskModifiedResponse: response.riskReview.modifiedResponse
        )
    }
}
