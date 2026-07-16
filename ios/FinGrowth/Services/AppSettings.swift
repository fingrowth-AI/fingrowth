import Foundation
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@Observable
final class AppSettings {
    static let backendURLKey = "settings.backend_url"
    static let appearanceKey = "settings.appearance"
    static let onDeviceModelEnabledKey = "settings.on_device_model_enabled"
    static let portfolioPrivacyLevelKey = "settings.portfolio_privacy_level"
    static let hasSeenOnboardingKey = "settings.has_seen_onboarding"

    // The default backend base URL depends on the build configuration. Debug
    // builds (simulator/dev) talk to a locally running FastAPI backend, while
    // Release builds (TestFlight/App Store) default to the hosted production
    // API. The user can always override this in Settings; this only supplies the
    // first-run value and the reset target.
    static let defaultBackendURL: String = {
        #if DEBUG
        return "http://localhost:8000"
        #else
        return "https://api.fingrowth.app"
        #endif
    }()

    @ObservationIgnored private let defaults: UserDefaults

    var backendURL: String {
        didSet {
            defaults.set(backendURL, forKey: Self.backendURLKey)
        }
    }

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    // Gates the on-device Gemma model. Off by default so a dev build never
    // auto-starts the ~2.5GB first-launch download just because the
    // swift-llama.cpp package happens to be linked — the download begins only
    // when the user explicitly opts in. Production ships with this on.
    var onDeviceModelEnabled: Bool {
        didSet {
            defaults.set(onDeviceModelEnabled, forKey: Self.onDeviceModelEnabledKey)
        }
    }

    // How much portfolio context the Differential Privacy module (P5-05) is
    // allowed to share with the cloud. Defaults to moderate.
    var portfolioPrivacyLevel: PortfolioPrivacyLevel {
        didSet {
            defaults.set(portfolioPrivacyLevel.rawValue, forKey: Self.portfolioPrivacyLevelKey)
        }
    }

    // V12-05: whether first-run onboarding (privacy model, research-not-advice
    // framing, CSV import) has been shown. False on a fresh install so the
    // onboarding appears once, then never again.
    var hasSeenOnboarding: Bool {
        didSet {
            defaults.set(hasSeenOnboarding, forKey: Self.hasSeenOnboardingKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? Self.defaultBackendURL
        let storedAppearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:))
        self.appearance = storedAppearance ?? .system
        self.onDeviceModelEnabled = defaults.bool(forKey: Self.onDeviceModelEnabledKey)
        let storedPrivacy = defaults.string(forKey: Self.portfolioPrivacyLevelKey)
            .flatMap(PortfolioPrivacyLevel.init(rawValue:))
        self.portfolioPrivacyLevel = storedPrivacy ?? .moderate
        self.hasSeenOnboarding = defaults.bool(forKey: Self.hasSeenOnboardingKey)
    }

    func resetBackendURL() {
        backendURL = Self.defaultBackendURL
    }
}
