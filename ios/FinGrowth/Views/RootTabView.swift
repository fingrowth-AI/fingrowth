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
        .tint(FinTheme.accent)
        .preferredColorScheme(settings.appearance.colorScheme)
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

enum FinTheme {
    static let accent = Color(red: 0.00, green: 0.78, blue: 0.36)
    static let mint = Color(red: 0.00, green: 0.78, blue: 0.36)
    static let violet = Color(red: 0.42, green: 0.42, blue: 0.48)
    static let amber = Color(red: 0.96, green: 0.64, blue: 0.16)
    static let danger = Color(red: 0.92, green: 0.19, blue: 0.25)

    static func page(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : .white
    }

    static func panel(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.04, green: 0.04, blue: 0.04)
            : .white
    }

    static func field(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.08)
            : Color(red: 0.96, green: 0.97, blue: 0.96)
    }

    static func border(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }
}

struct MarketBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FinTheme.page(for: colorScheme)
        .ignoresSafeArea()
    }
}

struct GlassPanel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FinTheme.panel(for: colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(FinTheme.border(for: colorScheme), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
