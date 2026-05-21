import Foundation
import SwiftData

@Model
final class PrivateLedger {
    @Attribute(.unique) var id: UUID
    var accountName: String
    var importedAt: Date
    var rawCSVDigest: String
    // Brokerage/source the CSV was recognized as (e.g. "Fidelity"). Optional so
    // pre-V3 rows migrate cleanly; the P4-05 parser stamps it at import time.
    var sourceBrokerage: String?
    // Imported lots. Populated by the CSV parser in P4-05; the Portfolio
    // Holdings view renders these alongside live paper positions (P4-04).
    @Relationship(deleteRule: .cascade, inverse: \LedgerHolding.ledger)
    var holdings: [LedgerHolding]

    init(
        id: UUID = UUID(),
        accountName: String,
        importedAt: Date = .now,
        rawCSVDigest: String = "",
        sourceBrokerage: String? = nil,
        holdings: [LedgerHolding] = []
    ) {
        self.id = id
        self.accountName = accountName
        self.importedAt = importedAt
        self.rawCSVDigest = rawCSVDigest
        self.sourceBrokerage = sourceBrokerage
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
    // Optional richer fields from the brokerage export (design §8.1 Holding).
    // Optional both because not every format ships them and so pre-V3 rows
    // migrate without a default.
    var purchaseDate: Date?
    var accountType: String?
    var ledger: PrivateLedger?

    init(
        ticker: String,
        quantity: Double,
        costBasis: Double,
        purchaseDate: Date? = nil,
        accountType: String? = nil,
        ledger: PrivateLedger? = nil
    ) {
        self.ticker = ticker.uppercased()
        self.quantity = quantity
        self.costBasis = costBasis
        self.purchaseDate = purchaseDate
        self.accountType = accountType
        self.ledger = ledger
    }
}
