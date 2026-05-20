import SwiftUI
import SwiftData

@main
struct FinGrowthApp: App {
    @State private var settings = AppSettings()
    private let container: ModelContainer

    init() {
        do {
            container = try AppContainer.makeContainer()
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(settings: settings)
        }
        .modelContainer(container)
    }
}
