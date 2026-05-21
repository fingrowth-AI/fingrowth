import Foundation
import SwiftData

@Model
final class PrivateLedger {
    @Attribute(.unique) var id: UUID
    var accountName: String
    var importedAt: Date
    var rawCSVDigest: String
    // Imported lots. Populated by the CSV parser in P4-05; the Portfolio
    // Holdings view renders these alongside live paper positions (P4-04).
    @Relationship(deleteRule: .cascade, inverse: \LedgerHolding.ledger)
    var holdings: [LedgerHolding]

    init(
        id: UUID = UUID(),
        accountName: String,
        importedAt: Date = .now,
        rawCSVDigest: String = "",
        holdings: [LedgerHolding] = []
    ) {
        self.id = id
        self.accountName = accountName
        self.importedAt = importedAt
        self.rawCSVDigest = rawCSVDigest
        self.holdings = holdings
    }
}

// A single imported holding row (device-only, part of PrivateLedger). Kept
// minimal for P4-04; the P4-05 CSV parser owns populating it from brokerage
// exports.
@Model
final class LedgerHolding {
    var ticker: String
    var quantity: Double
    var costBasis: Double
    var ledger: PrivateLedger?

    init(ticker: String, quantity: Double, costBasis: Double, ledger: PrivateLedger? = nil) {
        self.ticker = ticker.uppercased()
        self.quantity = quantity
        self.costBasis = costBasis
        self.ledger = ledger
    }
}
