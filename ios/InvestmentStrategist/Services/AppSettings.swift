import Foundation
import Observation

@Observable
final class AppSettings {
    static let backendURLKey = "settings.backend_url"
    static let defaultBackendURL = "http://localhost:8000"

    @ObservationIgnored private let defaults: UserDefaults

    var backendURL: String {
        didSet {
            defaults.set(backendURL, forKey: Self.backendURLKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? Self.defaultBackendURL
    }

    func resetBackendURL() {
        backendURL = Self.defaultBackendURL
    }
}
