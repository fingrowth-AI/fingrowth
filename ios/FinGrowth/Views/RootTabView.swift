import SwiftUI
import SwiftData

struct RootTabView: View {
    @Bindable var settings: AppSettings
    let apiClient: APIClient
    let paperTradingClient: PaperTradingService
    @State private var selection: RootTab = .research
    @State private var paperTradePrefill = PaperTradePrefill()
    @Environment(\.modelContext) private var modelContext
    @State private var portfolioStore: PortfolioStore?

    var body: some View {
        TabView(selection: $selection) {
            ForEach(RootTab.allCases) { tab in
                view(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .onAppear {
            if portfolioStore == nil {
                portfolioStore = PortfolioStore(
                    client: paperTradingClient,
                    context: modelContext
                )
            }
        }
    }

    @ViewBuilder
    private func view(for tab: RootTab) -> some View {
        switch tab {
        case .research:
            ResearchView(
                apiClient: apiClient,
                paperTradePrefill: paperTradePrefill,
                onSwitchToPortfolio: { selection = .portfolio }
            )
        case .portfolio:
            if let portfolioStore {
                PortfolioView(
                    store: portfolioStore,
                    paperTradePrefill: paperTradePrefill
                )
            } else {
                ProgressView()
            }
        case .privacy:
            PrivacyView()
        case .settings:
            SettingsView(settings: settings)
        }
    }
}
