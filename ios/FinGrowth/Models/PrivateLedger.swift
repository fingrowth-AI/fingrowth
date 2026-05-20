import Foundation
import SwiftData

@Model
final class PrivateLedger {
    @Attribute(.unique) var id: UUID
    var accountName: String
    var importedAt: Date
    var rawCSVDigest: String

    init(
        id: UUID = UUID(),
        accountName: String,
        importedAt: Date = .now,
        rawCSVDigest: String = ""
    ) {
        self.id = id
        self.accountName = accountName
        self.importedAt = importedAt
        self.rawCSVDigest = rawCSVDigest
    }
}
