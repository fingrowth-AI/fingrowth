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
    static let defaultBackendURL = "http://localhost:8000"

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
    }

    func resetBackendURL() {
        backendURL = Self.defaultBackendURL
    }
}
