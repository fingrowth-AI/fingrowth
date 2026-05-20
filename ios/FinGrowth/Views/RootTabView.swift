import SwiftUI

struct RootTabView: View {
    @Bindable var settings: AppSettings
    let apiClient: APIClient
    @State private var selection: RootTab = .research

    var body: some View {
        TabView(selection: $selection) {
            ForEach(RootTab.allCases) { tab in
                view(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
    }

    @ViewBuilder
    private func view(for tab: RootTab) -> some View {
        switch tab {
        case .research:
            ResearchView(apiClient: apiClient)
        case .portfolio:
            PortfolioView()
        case .privacy:
            PrivacyView()
        case .settings:
            SettingsView(settings: settings)
        }
    }
}
