import XCTest
@testable import FinGrowth

// V8-01: the coordinator turns a verified identity token into a stored session.
@MainActor
final class AuthCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        service: AuthServicing
    ) -> (AuthCoordinator, SessionStore) {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        return (AuthCoordinator(authService: service, sessionStore: store), store)
    }

    func testSuccessfulSignInStoresSession() async {
        let service = StubAuthService(
            result: AppleSignInResult(sessionToken: "sess-9", userID: "user-9", created: true)
        )
        let (coordinator, store) = makeCoordinator(service: service)

        await coordinator.completeSignIn(identityToken: "apple-token")

        XCTAssertTrue(coordinator.isSignedIn)
        XCTAssertEqual(store.token, "sess-9")
        XCTAssertEqual(store.userID, "user-9")
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertFalse(coordinator.isAuthenticating)
    }

    func testFailedSignInSurfacesErrorAndStaysSignedOut() async {
        let service = StubAuthService(error: AuthClientError.rejected(statusCode: 401, message: "nope"))
        let (coordinator, store) = makeCoordinator(service: service)

        await coordinator.completeSignIn(identityToken: "bad")

        XCTAssertFalse(coordinator.isSignedIn)
        XCTAssertNil(store.token)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testSignOutClearsSession() async {
        let service = StubAuthService(
            result: AppleSignInResult(sessionToken: "t", userID: "u", created: false)
        )
        let (coordinator, _) = makeCoordinator(service: service)
        await coordinator.completeSignIn(identityToken: "x")
        XCTAssertTrue(coordinator.isSignedIn)

        coordinator.signOut()
        XCTAssertFalse(coordinator.isSignedIn)
    }
}

private struct StubAuthService: AuthServicing {
    var result: AppleSignInResult?
    var error: Error?

    init(result: AppleSignInResult) { self.result = result }
    init(error: Error) { self.error = error }

    func exchangeAppleToken(_ identityToken: String) async throws -> AppleSignInResult {
        if let error { throw error }
        return result!
    }
}
