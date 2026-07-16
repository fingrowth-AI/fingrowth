import SwiftUI
import SwiftData
import UIKit

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
        // Keyboard ergonomics, app-wide: dragging any scroll view tucks the
        // keyboard away interactively (environment-propagated, so it reaches
        // every ScrollView/Form/List including sheets). Tap-to-dismiss is NOT
        // applied here: a tap gesture over UIKit-backed Lists/Forms steals row
        // buttons' taps, so it's attached per-screen to ScrollView-based
        // layouts only (see ResearchView).
        .scrollDismissesKeyboard(.interactively)
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
        // V12-05: first-run onboarding (privacy model, research-not-advice
        // framing, CSV import). Shown once on a fresh install, then never again.
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasSeenOnboarding },
            set: { if !$0 { settings.hasSeenOnboarding = true } }
        )) {
            OnboardingView(settings: settings)
        }
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
                    gemma: gemma,
                    onSwitchToResearch: { selection = .research }
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

// FG design tokens — the "Refined OLED" direction from design/screens-after.jsx:
// dark green-tinted neutrals, structured cards, one green accent. The dark
// values are the reference verbatim; light values are derived equivalents so
// the system-appearance setting keeps working. Spacing rhythm app-wide: 16pt
// screen margins, 12pt between cards, 18pt card radius, 1px `line` borders.
enum FinTheme {
    // Accents (appearance-invariant).
    static let accent = Color(red: 0x34 / 255.0, green: 0xD8 / 255.0, blue: 0x7B / 255.0)
    static let mint = accent
    static let amber = Color(red: 0xE9 / 255.0, green: 0xA2 / 255.0, blue: 0x3B / 255.0)
    static let danger = Color(red: 0xFF / 255.0, green: 0x62 / 255.0, blue: 0x59 / 255.0)
    // Dim washes behind green/amber chips (FG.greenDim / FG.amberDim).
    static let accentDim = accent.opacity(0.13)
    static let amberDim = amber.opacity(0.14)
    // Text/icon color on a solid green fill (the dark forest from the comps).
    static let onAccent = Color(red: 0x05 / 255.0, green: 0x23 / 255.0, blue: 0x0F / 255.0)

    // Surfaces (dynamic). FG.bg / FG.cardSolid / FG.inset / FG.line.
    static let pageBG = dynamic(dark: 0x0A0D0B, light: 0xF4F6F4)
    static let card = dynamic(dark: 0x141A16, light: 0xFFFFFF)
    static let inset = dynamic(dark: 0x1D2420, light: 0xE9EDEA)
    // Selected segment fill inside an inset segmented control.
    static let segment = dynamic(dark: 0x39433D, light: 0xFFFFFF)
    static let line = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.08)
    })

    // Text tiers (FG.t1 / FG.t2 / FG.t3).
    static let textPrimary = dynamic(dark: 0xF2F5F3, light: 0x131715)
    static let textSecondary = dynamic(dark: 0x94A29B, light: 0x5C6862)
    static let textTertiary = dynamic(dark: 0x5F6B65, light: 0x8B958F)

    static func page(for colorScheme: ColorScheme) -> Color { pageBG }

    static func panel(for colorScheme: ColorScheme) -> Color { card }

    static func field(for colorScheme: ColorScheme) -> Color { inset }

    static func border(for colorScheme: ColorScheme) -> Color { line }

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }

    // UIKit-level chrome the SwiftUI API can't reach: the flat tab bar (hairline
    // top border, green active / tertiary inactive — FgTabBarAfter) and the
    // inset segmented controls. Called once at app startup.
    static func applyChrome() {
        let tabBar = UITabBarAppearance()
        tabBar.configureWithDefaultBackground()
        tabBar.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: 0x0A0D0B).withAlphaComponent(0.92)
                : UIColor(rgb: 0xF4F6F4).withAlphaComponent(0.92)
        }
        tabBar.shadowColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.07)
                : UIColor.black.withAlphaComponent(0.08)
        }
        let inactive = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: 0x6E7A73) : UIColor(rgb: 0x8B958F)
        }
        let active = UIColor(rgb: 0x34D87B)
        for item in [tabBar.stackedLayoutAppearance, tabBar.inlineLayoutAppearance, tabBar.compactInlineLayoutAppearance] {
            item.normal.iconColor = inactive
            item.normal.titleTextAttributes = [.foregroundColor: inactive]
            item.selected.iconColor = active
            item.selected.titleTextAttributes = [.foregroundColor: active]
        }
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: 0x39433D) : UIColor.white
        }
        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(rgb: 0xF2F5F3) : UIColor(rgb: 0x131715)
            }],
            for: .selected
        )
        UISegmentedControl.appearance().setTitleTextAttributes(
            [.foregroundColor: UIColor { trait in
                trait.userInterfaceStyle == .dark ? UIColor(rgb: 0x94A29B) : UIColor(rgb: 0x5C6862)
            }],
            for: .normal
        )
    }
}

extension UIApplication {
    static func dismissKeyboard() {
        shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

// Tap-outside-to-dismiss for the keyboard. Safe on ScrollView-based screens,
// where child controls win their own taps and only "dead" space triggers the
// gesture. Do NOT attach to a Form or List: the gesture competes with the
// UIKit-backed row machinery and row buttons stop responding — Forms get a
// keyboard-toolbar Done button instead (see PaperTradeOrderSheet).
extension View {
    func dismissesKeyboardOnTap() -> some View {
        onTapGesture { UIApplication.dismissKeyboard() }
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

// Uppercased tertiary section label shown *outside* cards (AfSectionLabel).
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.9)
            .foregroundStyle(FinTheme.textTertiary)
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
            .background(FinTheme.card)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FinTheme.line, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
