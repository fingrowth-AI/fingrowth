import Foundation
import SwiftData

// SwiftData versioned schema for FinGrowth. Each VersionedSchema pins the
// model shapes that shipped at a given release so SchemaMigrationPlan can
// transform on-disk rows from one version to the next without crashing on
// added columns / unique constraints. V1 snapshots the exact P4-03 model
// graph, before paper-trade models and LedgerHolding existed.

// MARK: - V1 (P4-03)

enum AppSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            PrivateLedger.self,
            ShareableProfile.self,
            AuditEntry.self,
            ResearchHistoryEntry.self,
        ]
    }

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

    // Snapshot of the P4-03 row shape: no sessionID, no paper-trade linkage.
    // Field set must match what shipped so SwiftData can read existing rows
    // during V1 → V2 migration.
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
            analysisTypeRaw: String,
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
            self.analysisTypeRaw = analysisTypeRaw
            self.narrative = narrative
            self.confidence = confidence
            self.disclaimer = disclaimer
            self.indicatorsJSON = indicatorsJSON
            self.riskFlagsJSON = riskFlagsJSON
            self.riskApproved = riskApproved
            self.riskModifiedResponse = riskModifiedResponse
        }
    }
}

// MARK: - V2 (P4-04)

enum AppSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            PrivateLedger.self,
            LedgerHolding.self,
            ShareableProfile.self,
            AuditEntry.self,
            ResearchHistoryEntry.self,
            PaperTradeRecord.self,
            PortfolioSnapshot.self,
        ]
    }

    // Pinned pre-V5 ShareableProfile shape (no positionSizeBucketsJSON). V2–V4
    // all shipped this shape, so they reference AppSchemaV2.ShareableProfile;
    // only V5 adds the position-buckets column.
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

    // V2 shapes of the imported-portfolio models, pinned so V3 can add fields
    // (purchaseDate, accountType, sourceBrokerage) and drop PortfolioSnapshot
    // without corrupting the on-disk description of an existing V2 store. The
    // live types in PrivateLedger.swift are the *current* (V3) shapes.
    @Model
    final class PrivateLedger {
        @Attribute(.unique) var id: UUID
        var accountName: String
        var importedAt: Date
        var rawCSVDigest: String
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

    @Model
    final class LedgerHolding {
        var ticker: String
        var quantity: Double
        var costBasis: Double
        var ledger: PrivateLedger?

        init(ticker: String, quantity: Double, costBasis: Double, ledger: PrivateLedger? = nil) {
            self.ticker = ticker
            self.quantity = quantity
            self.costBasis = costBasis
            self.ledger = ledger
        }
    }

    // Dropped entirely in V3 (the Performance tracker now reads server-backed
    // Alpaca portfolio history instead of locally-captured snapshots), but
    // pinned here so a V2 → V3 migration knows the table to drop.
    @Model
    final class PortfolioSnapshot {
        @Attribute(.unique) var capturedDay: Date
        var marketValue: Double
        var costBasis: Double

        init(capturedDay: Date, marketValue: Double, costBasis: Double) {
            self.capturedDay = capturedDay
            self.marketValue = marketValue
            self.costBasis = costBasis
        }
    }

    // Adds sessionID (the cross-model link to
    // PaperTradeRecord.sourceResearchSessionID). sessionID is intentionally
    // *not* @Attribute(.unique): SwiftData applies the column's literal
    // default to every existing row during migration, so a schema-level
    // unique would crash V1 → V2 the moment any P4-03 history rows are on
    // disk. Uniqueness is enforced upstream — the backend issues a fresh
    // session UUID per analysis, and AppMigrationPlan.migrateV1toV2
    // backfills a unique UUID per legacy row.
    @Model
    final class ResearchHistoryEntry {
        var sessionID: UUID = UUID()
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
            sessionID: UUID = UUID(),
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
            self.sessionID = sessionID
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
    }
}

typealias ResearchHistoryEntry = AppSchemaV2.ResearchHistoryEntry

// MARK: - V3 (P4-05 ledger fields + portfolio-history performance)

// V3 evolves the imported-portfolio models and retires PortfolioSnapshot:
//   * LedgerHolding gains purchaseDate / accountType (design §8.1 Holding).
//   * PrivateLedger gains sourceBrokerage (brokerage/source metadata).
//   * PortfolioSnapshot is removed — the Performance tracker now plots
//     server-backed Alpaca portfolio history (realised + unrealised equity).
// The current shapes live in PrivateLedger.swift, so V3 references the live
// types directly. All deltas are additive-optional or entity removal, so the
// V2 → V3 stage is lightweight.
enum AppSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            PrivateLedger.self,
            LedgerHolding.self,
            AppSchemaV2.ShareableProfile.self,
            AuditEntry.self,
            ResearchHistoryEntry.self,
            PaperTradeRecord.self,
        ]
    }

    // V3 shapes of the imported-portfolio models, pinned so V4 can add the
    // device-only PII fields (accountNumber / accountHolder) to PrivateLedger
    // without corrupting the on-disk description of a V3 store. The pair is
    // pinned together because of their bidirectional relationship.
    @Model
    final class PrivateLedger {
        @Attribute(.unique) var id: UUID
        var accountName: String
        var importedAt: Date
        var rawCSVDigest: String
        var sourceBrokerage: String?
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

    @Model
    final class LedgerHolding {
        var ticker: String
        var quantity: Double
        var costBasis: Double
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
            self.ticker = ticker
            self.quantity = quantity
            self.costBasis = costBasis
            self.purchaseDate = purchaseDate
            self.accountType = accountType
            self.ledger = ledger
        }
    }
}

// MARK: - V4 (P5-03 on-device PII extraction)

// V4 adds device-only PII fields to PrivateLedger (accountNumber /
// accountHolder) captured by the Gemma-powered CSV parser. They never leave
// the device. The current shapes live in PrivateLedger.swift, so V4 references
// the live types; the deltas are additive-optional, so V3 → V4 is lightweight.
enum AppSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            PrivateLedger.self,
            LedgerHolding.self,
            AppSchemaV2.ShareableProfile.self,
            AuditEntry.self,
            ResearchHistoryEntry.self,
            PaperTradeRecord.self,
        ]
    }
}

// MARK: - V5 (P5-05 position-size buckets in ShareableProfile)

// V5 adds positionSizeBucketsJSON to ShareableProfile so the Differential
// Privacy module can report the largest *position* (not the largest sector).
// The live ShareableProfile is the current (V5) shape; additive-optional, so
// V4 → V5 is lightweight.
enum AppSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            PrivateLedger.self,
            LedgerHolding.self,
            ShareableProfile.self,
            AuditEntry.self,
            ResearchHistoryEntry.self,
            PaperTradeRecord.self,
        ]
    }
}

// MARK: - Migration plan

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self, AppSchemaV4.self, AppSchemaV5.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5]
    }

    // Additive optional positionSizeBucketsJSON column on ShareableProfile.
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: AppSchemaV4.self,
        toVersion: AppSchemaV5.self
    )

    // Additive optional PII columns on PrivateLedger.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: AppSchemaV3.self,
        toVersion: AppSchemaV4.self
    )

    // Additive optional columns plus a dropped PortfolioSnapshot table —
    // SwiftData handles both without custom row work.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: AppSchemaV2.self,
        toVersion: AppSchemaV3.self
    )

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: AppSchemaV1.self,
        toVersion: AppSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            // SwiftData has just added the sessionID column with the
            // property's literal default, so every legacy row currently
            // shares one UUID. Stamp a fresh one per row so paper-trade
            // lookups by sessionID resolve to a single analysis.
            let descriptor = FetchDescriptor<ResearchHistoryEntry>()
            let entries = try context.fetch(descriptor)
            for entry in entries {
                entry.sessionID = UUID()
            }
            try context.save()
        }
    )
}
