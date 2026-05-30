import Foundation

// V8-01: exchanges an Apple identity token for a backend session token via
// POST /api/v1/auth/apple. Kept separate from the Sign in with Apple UI so the
// network exchange is unit-testable with an injected URLSession.

struct AppleSignInResult: Decodable, Equatable, Sendable {
    let sessionToken: String
    let userID: String
    let created: Bool

    private enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case userID = "user_id"
        case created
    }
}

enum AuthClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case rejected(statusCode: Int, message: String?)
    case network(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "The backend URL '\(value)' is not valid. Update it in Settings."
        case .rejected(let code, let message):
            return message ?? "Sign in was rejected by the backend (HTTP \(code))."
        case .network:
            return "Network error during sign in. Check your connection and try again."
        case .decoding:
            return "The backend sent a sign-in response we couldn't read."
        }
    }
}

protocol AuthServicing: Sendable {
    func exchangeAppleToken(_ identityToken: String) async throws -> AppleSignInResult
}

final class AuthClient: AuthServicing {
    private let baseURLProvider: @Sendable () -> String
    private let session: URLSession

    init(
        baseURLProvider: @escaping @Sendable () -> String,
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session
    }

    convenience init(settings: AppSettings, session: URLSession = .shared) {
        self.init(
            baseURLProvider: { [weak settings] in
                settings?.backendURL ?? AppSettings.defaultBackendURL
            },
            session: session
        )
    }

    func exchangeAppleToken(_ identityToken: String) async throws -> AppleSignInResult {
        let baseString = baseURLProvider()
        guard let baseURL = URL(string: baseString),
              let url = URL(string: "/api/v1/auth/apple", relativeTo: baseURL)
        else {
            throw AuthClientError.invalidBaseURL(baseString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(["identity_token": identityToken])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthClientError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthClientError.network("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail
            throw AuthClientError.rejected(statusCode: http.statusCode, message: detail)
        }
        do {
            return try JSONDecoder().decode(AppleSignInResult.self, from: data)
        } catch {
            throw AuthClientError.decoding(error.localizedDescription)
        }
    }

    private struct ErrorEnvelope: Decodable {
        let detail: String?
    }
}
