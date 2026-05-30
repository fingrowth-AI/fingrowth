import XCTest
@testable import FinGrowth

// Tests for P4-02 — APIClient SSE consumer.
//
// Acceptance criteria from the design doc:
//   * Stream displays progress updates in UI
//   * Network error shows user-friendly message
//   * Request cancellation closes SSE connection
//
// Plus the "Outputs" contract:
//   * APIClient.streamAnalysis(query:profile:) -> AsyncThrowingStream<...>
//   * Automatic reconnection on network interruption
//
// The transport is a mock SSEByteStreamProviding so tests stay offline and
// can simulate frame timing, mid-stream errors, and cancellation reliably.

final class APIClientTests: XCTestCase {

    // MARK: - SSE parser unit tests

    func testParserAccumulatesEventAndDataFromMultipleLines() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: "event: progress"))
        XCTAssertNil(parser.consume(line: "data: {\"stage\": \"researching\"}"))
        let frame = parser.consume(line: "")
        XCTAssertEqual(frame, SSEFrame(event: "progress", data: "{\"stage\": \"researching\"}"))
    }

    func testParserIgnoresCommentsAndKeepAlives() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: ": keep-alive"))
        XCTAssertNil(parser.consume(line: ""))
    }

    func testParserStripsTrailingCarriageReturn() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: "event: progress\r"))
        XCTAssertNil(parser.consume(line: "data: {}\r"))
        let frame = parser.consume(line: "\r")
        XCTAssertEqual(frame, SSEFrame(event: "progress", data: "{}"))
    }

    func testParserJoinsMultipleDataLinesWithNewline() {
        var parser = SSEParser()
        _ = parser.consume(line: "event: chunk")
        _ = parser.consume(line: "data: line one")
        _ = parser.consume(line: "data: line two")
        let frame = parser.consume(line: "")
        XCTAssertEqual(frame, SSEFrame(event: "chunk", data: "line one\nline two"))
    }

    func testParserStripsSingleLeadingSpaceAfterColon() {
        var parser = SSEParser()
        _ = parser.consume(line: "event:no_space")
        _ = parser.consume(line: "data:tight")
        let frame = parser.consume(line: "")
        XCTAssertEqual(frame, SSEFrame(event: "no_space", data: "tight"))
    }

    func testParserFlushFinalFrameWithoutTrailingBlank() {
        var parser = SSEParser()
        _ = parser.consume(line: "event: final_result")
        _ = parser.consume(line: "data: {}")
        let frame = parser.flush()
        XCTAssertEqual(frame, SSEFrame(event: "final_result", data: "{}"))
    }

    func testParserFlushesPreviousFrameWhenNextEventStarts() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume(line: "event: progress"))
        XCTAssertNil(parser.consume(line: "data: {\"stage\": \"researching\"}"))
        let progress = parser.consume(line: "event: partial_result")
        XCTAssertEqual(progress, SSEFrame(event: "progress", data: "{\"stage\": \"researching\"}"))
        XCTAssertNil(parser.consume(line: "data: {\"stage\": \"research\", \"research\": {\"filings\": [], \"news\": []}}"))
        let partial = parser.consume(line: "event: final_result")
        XCTAssertEqual(
            partial,
            SSEFrame(
                event: "partial_result",
                data: "{\"stage\": \"research\", \"research\": {\"filings\": [], \"news\": []}}"
            )
        )
    }

    // MARK: - streamAnalysis happy path

    func testStreamAnalysisYieldsProgressPartialAndFinalEvents() async throws {
        let final = sampleFinalResultLines()
        let lines = [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
            "event: partial_result",
            "data: {\"stage\": \"research\", \"research\": {\"filings\": [], \"news\": []}}",
            "",
            "event: progress",
            "data: {\"stage\": \"analyzing\"}",
            "",
            "event: partial_result",
            "data: {\"stage\": \"analysis\", \"analysis\": {\"technical\": {\"rsi\": 55.0}, \"confidence\": \"high\"}}",
            "",
            "event: progress",
            "data: {\"stage\": \"reviewing\"}",
            "",
            "event: final_result",
            "data: \(final)",
            "",
        ]
        let transport = MockSSETransport(lines: lines)
        let client = makeClient(transport: transport)

        var collected: [AnalysisEvent] = []
        for try await event in client.streamAnalysis(query: sampleQuery()) {
            collected.append(event)
        }

        XCTAssertEqual(collected.count, 6)
        guard case .progress(let s0) = collected[0] else { return XCTFail("expected progress") }
        XCTAssertEqual(s0, "researching")
        guard case .partialResearch = collected[1] else { return XCTFail("expected partial research") }
        guard case .progress(let s2) = collected[2] else { return XCTFail("expected progress") }
        XCTAssertEqual(s2, "analyzing")
        guard case .partialAnalysis(let technical, let confidence) = collected[3] else {
            return XCTFail("expected partial analysis")
        }
        XCTAssertEqual(confidence, "high")
        XCTAssertEqual(technical["rsi"]?.asDouble, 55.0)
        guard case .progress(let s4) = collected[4] else { return XCTFail("expected progress") }
        XCTAssertEqual(s4, "reviewing")
        guard case .finalResult(let response) = collected[5] else {
            return XCTFail("expected final_result")
        }
        XCTAssertEqual(response.ticker, "AAPL")
    }

    func testRequestBodyContainsQueryProfileAndSnakeCaseKeys() async throws {
        let lines = [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
        ]
        let transport = MockSSETransport(lines: lines)
        let client = makeClient(transport: transport)
        let profile = PortfolioProfile(
            sectorWeights: ["technology": 0.8],
            largestPosition: "concentrated",
            diversification: "low",
            riskOrientation: "growth"
        )

        var iterator = client.streamAnalysis(query: sampleQuery(), profile: profile).makeAsyncIterator()
        _ = try await iterator.next()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/analysis/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["query"] as? String, "Is AAPL overbought?")
        XCTAssertEqual(json["ticker"] as? String, "AAPL")
        XCTAssertEqual(json["analysis_type"] as? String, "technical")
        let profileJSON = try XCTUnwrap(json["portfolio_profile"] as? [String: Any])
        XCTAssertEqual(profileJSON["risk_orientation"] as? String, "growth")
        let sectors = try XCTUnwrap(profileJSON["sector_weights"] as? [String: Any])
        XCTAssertEqual(sectors["technology"] as? Double, 0.8)
    }

    // MARK: - Auth-shaped contract (V7-05)

    func testRequestAlwaysSendsBearerAuthorizationHeader() async throws {
        let transport = MockSSETransport(lines: ["event: progress", "data: {\"stage\": \"researching\"}", ""])
        let client = makeClient(transport: transport)

        var iterator = client.streamAnalysis(query: sampleQuery()).makeAsyncIterator()
        _ = try await iterator.next()

        let request = try XCTUnwrap(transport.requests.first)
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.hasPrefix("Bearer "), "expected a Bearer header, got \(authorization)")
        XCTAssertEqual(authorization, "Bearer \(APIClient.placeholderToken)")
    }

    func testRequestUsesInjectedToken() async throws {
        let transport = MockSSETransport(lines: ["event: progress", "data: {\"stage\": \"researching\"}", ""])
        let client = APIClient(
            baseURLProvider: { "http://test.local" },
            tokenProvider: { "session-xyz" },
            transport: transport,
            sleeper: { _ in }
        )

        var iterator = client.streamAnalysis(query: sampleQuery()).makeAsyncIterator()
        _ = try await iterator.next()

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-xyz")
    }

    // MARK: - Error path: SSE error frame surfaces as serverError event

    func testServerErrorFrameIsEmittedAsServerErrorEvent() async throws {
        let lines = [
            "event: error",
            "data: {\"message\": \"simulated graph failure\"}",
            "",
        ]
        let client = makeClient(transport: MockSSETransport(lines: lines))

        var collected: [AnalysisEvent] = []
        for try await event in client.streamAnalysis(query: sampleQuery()) {
            collected.append(event)
        }

        XCTAssertEqual(collected.count, 1)
        guard case .serverError(let message) = collected[0] else {
            return XCTFail("expected serverError, got \(collected)")
        }
        XCTAssertTrue(message.contains("simulated graph failure"), "got \(message)")
    }

    // MARK: - Error path: HTTP non-2xx surfaces as user-friendly error

    func testHTTPNon2xxSurfacesAsLocalizedRequestFailure() async {
        let transport = MockSSETransport(lines: [], statusCode: 502)
        let client = makeClient(transport: transport, retryPolicy: .none)

        await XCTAssertThrowsErrorAsync(
            for: client.streamAnalysis(query: sampleQuery())
        ) { error in
            guard let apiError = error as? APIClientError else {
                return XCTFail("expected APIClientError, got \(error)")
            }
            XCTAssertEqual(apiError, .requestFailed(statusCode: 502))
            let message = apiError.errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("backend"), "got '\(message)'")
        }
    }

    // MARK: - Error path: invalid base URL is user-friendly

    func testInvalidBaseURLSurfacesAsLocalizedError() async {
        let client = APIClient(
            baseURLProvider: { "" },
            transport: MockSSETransport(lines: []),
            retryPolicy: .none
        )

        await XCTAssertThrowsErrorAsync(
            for: client.streamAnalysis(query: sampleQuery())
        ) { error in
            guard let apiError = error as? APIClientError,
                  case .invalidBaseURL = apiError
            else {
                return XCTFail("expected invalidBaseURL, got \(error)")
            }
            XCTAssertTrue(
                (apiError.errorDescription ?? "").contains("Settings"),
                "user-facing message should mention Settings"
            )
        }
    }

    func testInvalidEventErrorIncludesEventPayloadAndCodingPath() async {
        let lines = [
            "event: partial_result",
            "data: {\"stage\": \"analysis\", \"analysis\": {\"technical\": {}, \"confidence\": 42}}",
            "",
        ]
        let client = makeClient(transport: MockSSETransport(lines: lines), retryPolicy: .none)

        await XCTAssertThrowsErrorAsync(
            for: client.streamAnalysis(query: sampleQuery())
        ) { error in
            guard let apiError = error as? APIClientError,
                  case .invalidEvent(let detail) = apiError
            else {
                return XCTFail("expected invalidEvent, got \(error)")
            }
            XCTAssertTrue(detail.contains("partial_result"), "got \(detail)")
            XCTAssertTrue(detail.contains("analysis.confidence"), "got \(detail)")
            XCTAssertTrue(detail.contains("Payload starts"), "got \(detail)")
        }
    }

    // MARK: - Reconnection on transient network errors

    func testTransientNetworkErrorRetriesAndSucceeds() async throws {
        let transport = MockSSETransport(scripts: [
            .failure(URLError(.networkConnectionLost)),
            .success([
                "event: progress",
                "data: {\"stage\": \"researching\"}",
                "",
            ]),
        ])
        let client = makeClient(transport: transport)

        var collected: [AnalysisEvent] = []
        for try await event in client.streamAnalysis(query: sampleQuery()) {
            collected.append(event)
        }

        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(transport.requestCount, 2, "transient failure should trigger a retry")
    }

    func testRetryGivesUpAfterMaxAttempts() async {
        let transport = MockSSETransport(scripts: [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(
            for: client.streamAnalysis(query: sampleQuery())
        ) { error in
            guard let apiError = error as? APIClientError, case .network = apiError else {
                return XCTFail("expected .network, got \(error)")
            }
            XCTAssertTrue(
                (apiError.errorDescription ?? "")
                    .lowercased()
                    .contains("network"),
                "expected user-friendly network message"
            )
        }
        XCTAssertEqual(transport.requestCount, 3, "should retry up to maxAttempts")
    }

    func testNonRetryableNetworkErrorBubblesImmediately() async {
        let transport = MockSSETransport(scripts: [
            .failure(URLError(.badURL)),
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsErrorAsync(
            for: client.streamAnalysis(query: sampleQuery())
        ) { _ in
            // success — error surfaced
        }
        XCTAssertEqual(transport.requestCount, 1, "non-retryable errors must not retry")
    }

    // MARK: - Cancellation closes the SSE connection

    func testCancellationTearsDownUnderlyingStream() async throws {
        let transport = MockSSETransport(lines: [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
        ], frameDelay: .milliseconds(50))
        let client = makeClient(transport: transport)

        let stream = client.streamAnalysis(query: sampleQuery())
        let task = Task<Void, Error> {
            for try await _ in stream {
                // Cancel after the first event arrives.
                throw CancellationError()
            }
        }
        do {
            try await task.value
        } catch {
            // Expected.
        }

        // Give the transport's onTermination a moment to fire.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThanOrEqual(
            transport.terminations,
            1,
            "cancelling the consumer must terminate the underlying SSE stream"
        )
    }

    func testStreamEndedWithFinalResultStopsRetryingEvenIfClosedEarly() async throws {
        // Two scripts: first returns a complete final_result then closes.
        let lines = [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
            "event: final_result",
            "data: \(sampleFinalResultLines())",
            "",
        ]
        let transport = MockSSETransport(lines: lines)
        let client = makeClient(transport: transport)

        var collected: [AnalysisEvent] = []
        for try await event in client.streamAnalysis(query: sampleQuery()) {
            collected.append(event)
        }
        XCTAssertEqual(transport.requestCount, 1, "no retry after final_result")
        XCTAssertTrue(collected.contains(where: {
            if case .finalResult = $0 { return true } else { return false }
        }))
    }

    func testStreamThrowingAfterFinalResultDoesNotRetry() async throws {
        // The connection drops *after* the final_result frame is delivered but
        // before a clean close. We already have the answer — re-running the
        // analysis would be wasteful and could double-bill the backend.
        let lines = [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
            "event: final_result",
            "data: \(sampleFinalResultLines())",
            "",
        ]
        let transport = MockSSETransport(scripts: [
            .successThenError(lines, URLError(.networkConnectionLost)),
        ])
        let client = makeClient(transport: transport)

        var collected: [AnalysisEvent] = []
        do {
            for try await event in client.streamAnalysis(query: sampleQuery()) {
                collected.append(event)
            }
        } catch {
            // A trailing throw may still surface as a stream error; that's fine
            // as long as we delivered the final_result and didn't retry.
        }

        XCTAssertEqual(transport.requestCount, 1, "must not retry once final_result was delivered")
        XCTAssertTrue(collected.contains(where: {
            if case .finalResult = $0 { return true } else { return false }
        }), "final_result should have been yielded before the drop")
    }

    // MARK: - Helpers

    private func makeClient(
        transport: SSEByteStreamProviding,
        retryPolicy: APIClient.RetryPolicy = .init(
            maxAttempts: 3,
            initialBackoff: .milliseconds(1),
            maxBackoff: .milliseconds(2)
        )
    ) -> APIClient {
        APIClient(
            baseURLProvider: { "http://test.local" },
            transport: transport,
            retryPolicy: retryPolicy,
            sleeper: { _ in }  // skip backoff sleep
        )
    }

    private func sampleQuery() -> AnalysisQuery {
        AnalysisQuery(query: "Is AAPL overbought?", ticker: "AAPL", analysisType: .technical)
    }

    private func sampleFinalResultLines() -> String {
        // Compact JSON for a valid AnalysisResponse — keeps wire shape on one
        // line so the SSE framing matches what the backend emits.
        let session = "00000000-0000-0000-0000-000000000001"
        return """
        {"session_id": "\(session)", "ticker": "AAPL", "research": {"filings": [], "news": []}, "analysis": {"technical": {"rsi": 55.0}, "narrative": "RSI is 55.", "confidence": "high"}, "risk_review": {"approved": true, "flags": [], "modified_response": "RSI is 55.", "disclaimer": "informational only"}, "disclaimer": "informational only"}
        """
    }
}

// MARK: - Async helper

func XCTAssertThrowsErrorAsync<T>(
    for stream: AsyncThrowingStream<T, Error>,
    file: StaticString = #file,
    line: UInt = #line,
    _ inspector: (Error) -> Void = { _ in }
) async {
    do {
        for try await _ in stream {
            // drain until error
        }
        XCTFail("expected stream to throw", file: file, line: line)
    } catch {
        inspector(error)
    }
}

// MARK: - Mock SSE transport

final class MockSSETransport: SSEByteStreamProviding, @unchecked Sendable {
    enum Script {
        case success([String])
        case failure(Error)
        // Yield the lines, then throw — simulates a connection drop *after*
        // some/all frames have been delivered (e.g. after final_result).
        case successThenError([String], Error)
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private let frameDelay: Duration
    private let statusCode: Int

    private var _requests: [URLRequest] = []
    private var _terminations: Int = 0

    convenience init(
        lines: [String],
        statusCode: Int = 200,
        frameDelay: Duration = .zero
    ) {
        self.init(
            scripts: [.success(lines)],
            statusCode: statusCode,
            frameDelay: frameDelay
        )
    }

    init(
        scripts: [Script],
        statusCode: Int = 200,
        frameDelay: Duration = .zero
    ) {
        self.scripts = scripts
        self.statusCode = statusCode
        self.frameDelay = frameDelay
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var requestCount: Int { requests.count }

    var terminations: Int {
        lock.lock(); defer { lock.unlock() }
        return _terminations
    }

    func lineStream(
        for request: URLRequest
    ) async throws -> (SSELineStream, HTTPURLResponse) {
        lock.lock()
        _requests.append(request)
        let script: Script
        if scripts.isEmpty {
            script = .success([])
        } else {
            script = scripts.removeFirst()
        }
        lock.unlock()

        switch script {
        case .failure(let error):
            throw error
        case .success(let lines):
            return try await makeStream(lines: lines, request: request, throwingAfter: nil)
        case .successThenError(let lines, let error):
            return try await makeStream(lines: lines, request: request, throwingAfter: error)
        }
    }

    private func makeStream(
        lines: [String],
        request: URLRequest,
        throwingAfter error: Error?
    ) async throws -> (SSELineStream, HTTPURLResponse) {
        let delay = frameDelay
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                for line in lines {
                    if Task.isCancelled { break }
                    if delay != .zero {
                        try? await Task.sleep(for: delay)
                    }
                    continuation.yield(line)
                }
                continuation.finish(throwing: error)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self._terminations += 1
                self.lock.unlock()
                task.cancel()
            }
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://test.local")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (stream, response)
    }
}
