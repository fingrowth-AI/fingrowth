import Foundation
import SwiftData

// Persisted record of a completed research run. Lives in the SwiftData store
// alongside PrivateLedger / ShareableProfile so prior analyses survive app
// restarts (P4-03 acceptance: "Results persist in SwiftData history").
//
// The @Model declaration lives on AppSchemaV2.ResearchHistoryEntry — see
// AppSchema.swift for the schema versioning. Indicators and risk flags are
// serialized as JSON blobs to avoid an explosion of relationship tables for
// what is effectively dynamic LLM output.

extension ResearchHistoryEntry {
    var analysisType: AnalysisType {
        AnalysisType(rawValue: analysisTypeRaw) ?? .general
    }

    var indicators: [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: indicatorsJSON)) ?? [:]
    }

    var riskFlags: [RiskFlag] {
        (try? JSONDecoder().decode([RiskFlag].self, from: riskFlagsJSON)) ?? []
    }

    static func from(query: AnalysisQuery, response: AnalysisResponse, now: Date = Date()) -> ResearchHistoryEntry {
        let encoder = JSONEncoder()
        let indicators = (try? encoder.encode(response.analysis.technical)) ?? Data("{}".utf8)
        let flags = (try? encoder.encode(response.riskReview.flags)) ?? Data("[]".utf8)
        return ResearchHistoryEntry(
            sessionID: response.sessionId,
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
