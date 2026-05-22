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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? Self.defaultBackendURL
        let storedAppearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:))
        self.appearance = storedAppearance ?? .system
    }

    func resetBackendURL() {
        backendURL = Self.defaultBackendURL
    }
}
