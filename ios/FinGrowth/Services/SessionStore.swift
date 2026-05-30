import Foundation
import Observation
import Security

// V8-01: holds the backend session token issued after Sign in with Apple. The
// token is a bearer credential, so it lives in the Keychain (not UserDefaults).
// SessionStore is the single source of truth the API clients read their token
// from and the UI observes for signed-in state.
//
// Mirrors AppSettings: a plain @Observable class (not @MainActor) so the
// API clients' @Sendable tokenProvider closures can read `token` the same way
// they read `backendURL`.

struct SessionCredentials: Equatable, Sendable {
    var token: String
    var userID: String
}

// Persistence backend for the session credentials. Injectable so tests run
// without touching the real Keychain.
protocol SessionPersisting: Sendable {
    func load() -> SessionCredentials?
    func save(_ credentials: SessionCredentials)
    func clear()
}

@Observable
final class SessionStore {
    @ObservationIgnored private let persistence: SessionPersisting

    private(set) var credentials: SessionCredentials?

    var token: String? { credentials?.token }
    var userID: String? { credentials?.userID }
    var isSignedIn: Bool { credentials != nil }

    init(persistence: SessionPersisting = KeychainSessionPersistence()) {
        self.persistence = persistence
        self.credentials = persistence.load()
    }

    func save(token: String, userID: String) {
        let creds = SessionCredentials(token: token, userID: userID)
        credentials = creds
        persistence.save(creds)
    }

    func signOut() {
        credentials = nil
        persistence.clear()
    }
}

// MARK: - Keychain backing

// Stores the token + user id as a single JSON blob under one generic-password
// item. Simulator builds can read/write the app's own Keychain without any
// special entitlement.
struct KeychainSessionPersistence: SessionPersisting {
    private let service: String
    private let account = "session-credentials"

    init(service: String = "com.fingrowth.FinGrowth.session") {
        self.service = service
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> SessionCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data)
        else { return nil }
        return SessionCredentials(token: stored.token, userID: stored.userID)
    }

    func save(_ credentials: SessionCredentials) {
        guard let data = try? JSONEncoder().encode(
            StoredCredentials(token: credentials.token, userID: credentials.userID)
        ) else { return }

        // Upsert: delete any existing item, then add fresh.
        SecItemDelete(baseQuery() as CFDictionary)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private struct StoredCredentials: Codable {
        let token: String
        let userID: String
    }
}

// MARK: - In-memory backing (tests / previews)

final class InMemorySessionPersistence: SessionPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SessionCredentials?

    init(_ initial: SessionCredentials? = nil) {
        self.stored = initial
    }

    func load() -> SessionCredentials? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ credentials: SessionCredentials) {
        lock.lock(); defer { lock.unlock() }
        stored = credentials
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
