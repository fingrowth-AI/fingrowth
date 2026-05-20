import Foundation
import SwiftData

@Model
final class ShareableProfile {
    @Attribute(.unique) var id: UUID
    var totalValueBucket: String
    var sectorWeightsJSON: String
    var riskScore: Double
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        totalValueBucket: String,
        sectorWeightsJSON: String = "{}",
        riskScore: Double = 0,
        generatedAt: Date = .now
    ) {
        self.id = id
        self.totalValueBucket = totalValueBucket
        self.sectorWeightsJSON = sectorWeightsJSON
        self.riskScore = riskScore
        self.generatedAt = generatedAt
    }
}
