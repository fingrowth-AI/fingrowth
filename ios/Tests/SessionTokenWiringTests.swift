import XCTest
@testable import FinGrowth

// V8-01: once signed in, both API clients must send the stored session token as
// the Bearer credential; before sign-in they fall back to the placeholder.
final class SessionTokenWiringTests: XCTestCase {

    private func ephemeralSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "wiring-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.backendURL = "http://test.local"
        return settings
    }

    func testAPIClientSendsStoredSessionToken() async throws {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        store.save(token: "live-session", userID: "u")

        let transport = MockSSETransport(
            lines: ["event: progress", "data: {\"stage\": \"researching\"}", ""]
        )
        let client = APIClient(
            settings: ephemeralSettings(),
            sessionStore: store,
            transport: transport
        )

        var iterator = client.streamAnalysis(
            query: AnalysisQuery(query: "q", ticker: "AAPL", analysisType: .technical)
        ).makeAsyncIterator()
        _ = try await iterator.next()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer live-session")
    }

    func testAPIClientFallsBackToPlaceholderWhenSignedOut() async throws {
        let store = SessionStore(persistence: InMemorySessionPersistence())

        let transport = MockSSETransport(
            lines: ["event: progress", "data: {\"stage\": \"researching\"}", ""]
        )
        let client = APIClient(
            settings: ephemeralSettings(),
            sessionStore: store,
            transport: transport
        )

        var iterator = client.streamAnalysis(
            query: AnalysisQuery(query: "q", ticker: "AAPL", analysisType: .technical)
        ).makeAsyncIterator()
        _ = try await iterator.next()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(APIClient.placeholderToken)"
        )
    }

    func testPaperTradingClientSendsStoredSessionToken() async throws {
        let store = SessionStore(persistence: InMemorySessionPersistence())
        store.save(token: "paper-session", userID: "u")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        let client = PaperTradingClient(
            settings: ephemeralSettings(),
            sessionStore: store,
            session: URLSession(configuration: config)
        )

        _ = try await client.listPositions()

        XCTAssertEqual(CapturingProtocol.lastAuthorization, "Bearer paper-session")
    }
}
