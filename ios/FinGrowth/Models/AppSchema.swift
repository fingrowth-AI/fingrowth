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

// MARK: - Migration plan

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AppSchemaV1.self, AppSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2]
    }

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
