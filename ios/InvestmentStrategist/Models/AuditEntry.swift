import Foundation
import SwiftData

@Model
final class AuditEntry {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var endpoint: String
    var direction: String
    var payloadDigest: String
    var summary: String

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        endpoint: String,
        direction: String,
        payloadDigest: String,
        summary: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.direction = direction
        self.payloadDigest = payloadDigest
        self.summary = summary
    }
}
