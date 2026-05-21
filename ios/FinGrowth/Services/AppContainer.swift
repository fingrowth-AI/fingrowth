import Foundation
import SwiftData

enum AppContainer {
    static func makeSchema() -> Schema {
        Schema(versionedSchema: AppSchemaV3.self)
    }

    static func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let schema = makeSchema()
        let resolvedURL = try storeURL ?? AppDataLocation.secureStoreURL()
        do {
            return try makeContainer(schema: schema, storeURL: resolvedURL)
        } catch {
            guard storeURL == nil else { throw error }
            try quarantineIncompatibleDefaultStore(at: resolvedURL)
            return try makeContainer(schema: schema, storeURL: resolvedURL)
        }
    }

    private static func makeContainer(schema: Schema, storeURL: URL) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: AppMigrationPlan.self,
            configurations: config
        )
        try AppDataLocation.applyStoreFileProtection(at: storeURL)
        return container
    }

    private static func quarantineIncompatibleDefaultStore(at storeURL: URL) throws {
        let fileManager = FileManager.default
        let storeFiles = AppDataLocation.storeFileURLs(for: storeURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !storeFiles.isEmpty else { return }

        let backupRoot = storeURL
            .deletingLastPathComponent()
            .appending(path: "IncompatibleStores", directoryHint: .isDirectory)
        let backupDir = backupRoot
            .appending(path: "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        for url in storeFiles {
            try fileManager.moveItem(
                at: url,
                to: backupDir.appending(path: url.lastPathComponent)
            )
        }
    }
}
