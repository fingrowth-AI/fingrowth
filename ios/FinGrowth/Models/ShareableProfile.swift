import Foundation
import SwiftData

@Model
final class ShareableProfile {
    @Attribute(.unique) var id: UUID
    var totalValueBucket: String
    var sectorWeightsJSON: String
    var riskScore: Double
    var generatedAt: Date
    // Generalized per-holding position-size buckets (design §8.2), computed at
    // import from individual holdings: a JSON array like
    // ["concentrated","large","moderate"]. Lets the Differential Privacy module
    // report the largest *position* (not the largest sector). Optional with a
    // default so pre-V5 rows migrate cleanly.
    var positionSizeBucketsJSON: String = "[]"

    init(
        id: UUID = UUID(),
        totalValueBucket: String,
        sectorWeightsJSON: String = "{}",
        riskScore: Double = 0,
        generatedAt: Date = .now,
        positionSizeBucketsJSON: String = "[]"
    ) {
        self.id = id
        self.totalValueBucket = totalValueBucket
        self.sectorWeightsJSON = sectorWeightsJSON
        self.riskScore = riskScore
        self.generatedAt = generatedAt
        self.positionSizeBucketsJSON = positionSizeBucketsJSON
    }
}
