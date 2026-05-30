import XCTest
@testable import FinGrowth

// V8-01: the session store holds the backend token and drives signed-in state.
final class SessionStoreTests: XCTestCase {

    func testStartsSignedOut() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.token)
        XCTAssertNil(store.userID)
    }

    func testSavePersistsTokenAndUser() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        store.save(token: "session-123", userID: "user-abc")

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.token, "session-123")
        XCTAssertEqual(store.userID, "user-abc")
    }

    func testSignOutClears() {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        store.save(token: "t", userID: "u")
        store.signOut()

        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.token)
    }

    func testCredentialsSurviveReinitFromPersistence() {
        let persistence = InMemorySessionPersistence()
        let first = SessionStore(persistence: persistence)
        first.save(token: "persisted-token", userID: "persisted-user")

        // A fresh store reading the same backing recovers the session — the
        // real app reloads from the Keychain on launch this way.
        let second = SessionStore(persistence: persistence)
        XCTAssertTrue(second.isSignedIn)
        XCTAssertEqual(second.token, "persisted-token")
        XCTAssertEqual(second.userID, "persisted-user")
    }

    func testSignOutPersistsAcrossReinit() {
        let persistence = InMemorySessionPersistence(
            SessionCredentials(token: "old", userID: "u")
        )
        let store = SessionStore(persistence: persistence)
        XCTAssertTrue(store.isSignedIn)
        store.signOut()

        XCTAssertNil(SessionStore(persistence: persistence).token)
    }
}
