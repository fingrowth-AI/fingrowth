import XCTest
@testable import FinGrowth

// V8-01: AuthClient exchanges an Apple identity token for a backend session
// token via POST /api/v1/auth/apple.
final class AuthClientTests: XCTestCase {

    override func tearDown() {
        AuthStubProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> AuthClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthStubProtocol.self]
        return AuthClient(
            baseURLProvider: { "http://test.local" },
            session: URLSession(configuration: config)
        )
    }

    func testSuccessfulExchangeDecodesSessionResult() async throws {
        AuthStubProtocol.handler = { request in
            // Posts the identity token to the right path.
            XCTAssertEqual(request.url?.path, "/api/v1/auth/apple")
            let body = #"{"session_token": "sess-1", "user_id": "u-1", "created": true}"#
            return (200, Data(body.utf8))
        }

        let result = try await makeClient().exchangeAppleToken("apple-token")

        XCTAssertEqual(result.sessionToken, "sess-1")
        XCTAssertEqual(result.userID, "u-1")
        XCTAssertTrue(result.created)
    }

    func testRejectionSurfacesBackendDetail() async {
        AuthStubProtocol.handler = { _ in
            (401, Data(#"{"detail": "invalid Apple identity token"}"#.utf8))
        }

        do {
            _ = try await makeClient().exchangeAppleToken("bad")
            XCTFail("expected rejection")
        } catch let error as AuthClientError {
            guard case .rejected(let code, let message) = error else {
                return XCTFail("expected .rejected, got \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(message, "invalid Apple identity token")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInvalidBaseURLThrows() async {
        let client = AuthClient(baseURLProvider: { "" })
        do {
            _ = try await client.exchangeAppleToken("x")
            XCTFail("expected invalidBaseURL")
        } catch let error as AuthClientError {
            guard case .invalidBaseURL = error else {
                return XCTFail("expected .invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// Configurable URLProtocol returning a canned (status, body) for auth requests.
final class AuthStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = AuthStubProtocol.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
