import SwiftUI
import SwiftData

struct RootTabView: View {
    @Bindable var settings: AppSettings
    let apiClient: APIClient
    let paperTradingClient: PaperTradingService
    @Bindable var gemma: GemmaService
    @Bindable var authCoordinator: AuthCoordinator
    let sessionStore: SessionStore
    @State private var selection: RootTab = .research
    @State private var paperTradePrefill = PaperTradePrefill()
    @Environment(\.modelContext) private var modelContext
    @State private var portfolioStore: PortfolioStore?

    // The thermal banner is only meaningful when real on-device inference can
    // actually run: the user enabled it and the linked backend is the real
    // model (not the development stub).
    private var onDeviceModelActive: Bool {
        settings.onDeviceModelEnabled && gemma.usesRealModel
    }

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
        // App-wide thermal warning (P5-02): only when on-device AI is actually
        // enabled and using the real model — a hot device shouldn't claim AI is
        // throttled when nothing on-device is running (disabled or dev stub).
        .overlay(alignment: .top) {
            if onDeviceModelActive, let message = gemma.thermal.warningMessage {
                ThermalWarningBanner(message: message)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: gemma.thermal.warningMessage)
        .onAppear {
            if portfolioStore == nil {
                portfolioStore = PortfolioStore(
                    client: paperTradingClient,
                    context: modelContext
                )
            }
        }
        // Prepare the on-device model only when the user has opted in, so a
        // build with the real backend linked never auto-starts the ~2.5GB
        // first-launch download. The stub is instant/offline; the real backend
        // downloads (or no-ops once cached).
        .task(id: settings.onDeviceModelEnabled) {
            if settings.onDeviceModelEnabled {
                await gemma.prepare()
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
                onSwitchToPortfolio: { selection = .portfolio },
                gemma: gemma,
                settings: settings
            )
        case .portfolio:
            if let portfolioStore {
                PortfolioView(
                    store: portfolioStore,
                    paperTradePrefill: paperTradePrefill,
                    gemma: gemma
                )
            } else {
                ProgressView()
            }
        case .privacy:
            PrivacyView()
        case .settings:
            SettingsView(
                settings: settings,
                gemma: gemma,
                authCoordinator: authCoordinator,
                sessionStore: sessionStore
            )
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

struct ThermalWarningBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.high")
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FinTheme.amber)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 4, y: 2)
        .accessibilityElement(children: .combine)
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
