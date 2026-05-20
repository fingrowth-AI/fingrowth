import SwiftUI
import SwiftData

@main
struct FinGrowthApp: App {
    @State private var settings = AppSettings()
    private let container: ModelContainer
    private let apiClient: APIClient

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        do {
            container = try AppContainer.makeContainer()
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
        apiClient = APIClient(settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(settings: settings, apiClient: apiClient)
        }
        .modelContainer(container)
    }
}
