import Foundation

// Wire models for /api/v1/analysis/query.
// Keep field names mirroring the backend Pydantic schemas (see
// backend/app/models/schemas.py). The JSONEncoder/Decoder used by APIClient
// converts between snake_case on the wire and camelCase here.

enum AnalysisType: String, Codable, Sendable, CaseIterable, Identifiable {
    case fundamental, technical, general
    var id: String { rawValue }
}

struct PortfolioProfile: Codable, Sendable, Equatable, Hashable {
    var sectorWeights: [String: Double] = [:]
    var largestPosition: String?
    var diversification: String?
    var riskOrientation: String?
}

struct AnalysisQuery: Codable, Sendable, Equatable {
    var query: String
    var ticker: String
    var analysisType: AnalysisType
    var sessionId: UUID?
}

struct ResearchData: Codable, Sendable, Equatable {
    var filings: [JSONValue] = []
    var news: [JSONValue] = []
}

struct AnalysisData: Codable, Sendable, Equatable {
    var technical: [String: JSONValue] = [:]
    var narrative: String = ""
    var confidence: String = "insufficient_data"
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
