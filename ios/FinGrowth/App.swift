import SwiftUI
import SwiftData

@main
struct FinGrowthApp: App {
    @State private var settings = AppSettings()
    @State private var gemma = GemmaService.shared
    @State private var authCoordinator: AuthCoordinator
    private let sessionStore: SessionStore
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
        // V8-01: the session store is the single source of truth for the Bearer
        // token; both API clients read it, and the auth coordinator writes it
        // after Sign in with Apple.
        let sessionStore = SessionStore()
        self.sessionStore = sessionStore
        apiClient = APIClient(settings: settings, sessionStore: sessionStore)
        paperTradingClient = PaperTradingClient(settings: settings, sessionStore: sessionStore)
        _authCoordinator = State(initialValue: AuthCoordinator(
            authService: AuthClient(settings: settings),
            sessionStore: sessionStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                settings: settings,
                apiClient: apiClient,
                paperTradingClient: paperTradingClient,
                gemma: gemma,
                authCoordinator: authCoordinator,
                sessionStore: sessionStore
            )
        }
        .modelContainer(container)
    }
}
