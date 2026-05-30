import XCTest
@testable import FinGrowth

// V7-05: paper-trading API calls must also be auth-shaped — every request
// carries a Bearer header so V8's per-user trade partitioning is a fill.
final class PaperTradingClientTests: XCTestCase {

    override func tearDown() {
        CapturingProtocol.lastAuthorization = nil
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: config)
    }

    func testRequestsSendBearerAuthorizationHeader() async throws {
        let client = PaperTradingClient(
            baseURLProvider: { "http://test.local" },
            session: makeSession()
        )
        _ = try await client.listPositions()

        let authorization = try XCTUnwrap(CapturingProtocol.lastAuthorization)
        XCTAssertEqual(authorization, "Bearer \(APIClient.placeholderToken)")
    }

    func testUsesInjectedToken() async throws {
        let client = PaperTradingClient(
            baseURLProvider: { "http://test.local" },
            tokenProvider: { "session-abc" },
            session: makeSession()
        )
        _ = try await client.listOrders()

        XCTAssertEqual(CapturingProtocol.lastAuthorization, "Bearer session-abc")
    }
}

// Captures the outgoing request's Authorization header and returns a canned
// 200 envelope so the client's decode succeeds.
final class CapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var lastAuthorization: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CapturingProtocol.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let body = Data(#"{"positions": [], "orders": []}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
