import Foundation
import SwiftData

enum AppContainer {
    static func makeSchema() -> Schema {
        Schema([
            PrivateLedger.self,
            ShareableProfile.self,
            AuditEntry.self,
            ResearchHistoryEntry.self,
        ])
    }

    static func makeContainer(storeURL: URL? = nil) throws -> ModelContainer {
        let schema = makeSchema()
        let resolvedURL = try storeURL ?? AppDataLocation.secureStoreURL()
        let config = ModelConfiguration(
            schema: schema,
            url: resolvedURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: config)
        try AppDataLocation.applyStoreFileProtection(at: resolvedURL)
        return container
    }
}
