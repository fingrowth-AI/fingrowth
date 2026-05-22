import SwiftUI
import SwiftData

@main
struct FinGrowthApp: App {
    @State private var settings = AppSettings()
    @State private var gemma = GemmaService.shared
    private let container: ModelContainer
    private let apiClient: APIClient
    private let paperTradingClient: PaperTradingClient

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        do {
            container = try AppContainer.makeContainer()
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error)")
        }
        apiClient = APIClient(settings: settings)
        paperTradingClient = PaperTradingClient(settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                settings: settings,
                apiClient: apiClient,
                paperTradingClient: paperTradingClient,
                gemma: gemma
            )
        }
        .modelContainer(container)
    }
}
