import AuthenticationServices
import Foundation
import Observation

// V8-01: drives the Sign in with Apple flow — turns the Apple credential into a
// backend session token and stores it. The pure token-exchange path
// (`completeSignIn(identityToken:)`) is split out from the ASAuthorization
// plumbing so it can be unit-tested without the system UI.
@MainActor
@Observable
final class AuthCoordinator {
    @ObservationIgnored private let authService: AuthServicing
    @ObservationIgnored private let sessionStore: SessionStore

    private(set) var isAuthenticating = false
    var errorMessage: String?

    var isSignedIn: Bool { sessionStore.isSignedIn }

    init(authService: AuthServicing, sessionStore: SessionStore) {
        self.authService = authService
        self.sessionStore = sessionStore
    }

    // Configure the request the SignInWithAppleButton issues.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    // Handle the button's completion. Extracts the identity token and exchanges
    // it for a session token; surfaces a readable message on any failure.
    func handle(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled {
                return  // user backed out — not an error worth showing
            }
            errorMessage = error.localizedDescription
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                errorMessage = "Apple did not return an identity token."
                return
            }
            await completeSignIn(identityToken: identityToken)
        }
    }

    // Exchange an Apple identity token for a backend session token and persist
    // it. Testable in isolation from the ASAuthorization UI.
    func completeSignIn(identityToken: String) async {
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }
        do {
            let result = try await authService.exchangeAppleToken(identityToken)
            sessionStore.save(token: result.sessionToken, userID: result.userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        sessionStore.signOut()
    }
}
