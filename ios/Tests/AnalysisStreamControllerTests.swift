import XCTest
@testable import FinGrowth

// Verifies the SwiftUI-facing surface area of P4-02:
//   * Progress updates land on observable state in order.
//   * Network errors surface a user-friendly message.
//   * cancel() stops the stream and leaves the controller in .idle.

@MainActor
final class AnalysisStreamControllerTests: XCTestCase {

    func testProgressStagesAccumulateInObservableState() async throws {
        let lines = [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
            "event: progress",
            "data: {\"stage\": \"analyzing\"}",
            "",
            "event: progress",
            "data: {\"stage\": \"reviewing\"}",
            "",
            "event: final_result",
            "data: \(Self.sampleFinalJSON)",
            "",
        ]
        let controller = makeController(lines: lines)
        controller.start(query: Self.sampleQuery)

        try await waitForCompletion(of: controller)

        XCTAssertEqual(controller.stages, ["researching", "analyzing", "reviewing"])
        XCTAssertEqual(controller.phase, .completed)
        XCTAssertEqual(controller.finalResult?.ticker, "AAPL")
    }

    func testNetworkErrorPopulatesUserFriendlyMessage() async throws {
        let transport = MockSSETransport(scripts: [
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.notConnectedToInternet)),
        ])
        let client = makeClient(transport: transport)
        let controller = AnalysisStreamController(client: client)
        controller.start(query: Self.sampleQuery)

        try await waitForFailure(of: controller)

        let message = try XCTUnwrap(controller.errorMessage)
        XCTAssertTrue(
            message.lowercased().contains("network") ||
            message.lowercased().contains("connection"),
            "expected user-friendly network message, got '\(message)'"
        )
        if case .failed(let phaseMessage) = controller.phase {
            XCTAssertEqual(phaseMessage, message)
        } else {
            XCTFail("expected .failed phase, got \(controller.phase)")
        }
    }

    func testCancelStopsTheStreamAndReturnsToIdle() async throws {
        // Keep the stream open long enough to call cancel() between frames.
        let lines = [
            "event: progress",
            "data: {\"stage\": \"researching\"}",
            "",
            "event: progress",
            "data: {\"stage\": \"analyzing\"}",
            "",
            "event: final_result",
            "data: \(Self.sampleFinalJSON)",
            "",
        ]
        let transport = MockSSETransport(lines: lines, frameDelay: .milliseconds(20))
        let client = makeClient(transport: transport)
        let controller = AnalysisStreamController(client: client)

        controller.start(query: Self.sampleQuery)
        try await waitFor(controller, where: { !$0.stages.isEmpty })
        controller.cancel()

        // Give the cancellation propagation a tick.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.phase, .idle, "cancel should land us in idle")
        XCTAssertNil(controller.finalResult, "no final_result expected after cancel")
        XCTAssertGreaterThanOrEqual(transport.terminations, 1,
            "cancellation must close the underlying SSE connection")
    }

    // MARK: - Helpers

    private func makeController(lines: [String]) -> AnalysisStreamController {
        let transport = MockSSETransport(lines: lines, frameDelay: .milliseconds(1))
        return AnalysisStreamController(client: makeClient(transport: transport))
    }

    private func makeClient(transport: SSEByteStreamProviding) -> APIClient {
        APIClient(
            baseURLProvider: { "http://test.local" },
            transport: transport,
            retryPolicy: .init(
                maxAttempts: 3,
                initialBackoff: .milliseconds(1),
                maxBackoff: .milliseconds(2)
            ),
            sleeper: { _ in }
        )
    }

    private func waitForCompletion(
        of controller: AnalysisStreamController,
        timeout: TimeInterval = 2
    ) async throws {
        try await waitFor(controller, timeout: timeout) {
            if case .completed = $0.phase { return true }
            return false
        }
    }

    private func waitForFailure(
        of controller: AnalysisStreamController,
        timeout: TimeInterval = 2
    ) async throws {
        try await waitFor(controller, timeout: timeout) {
            if case .failed = $0.phase { return true }
            return false
        }
    }

    private func waitFor(
        _ controller: AnalysisStreamController,
        timeout: TimeInterval = 2,
        where predicate: (AnalysisStreamController) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(controller) {
            if Date() > deadline {
                XCTFail("timed out waiting for controller condition; phase=\(controller.phase)")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static let sampleQuery = AnalysisQuery(
        query: "Is AAPL overbought?",
        ticker: "AAPL",
        analysisType: .technical
    )

    static let sampleFinalJSON: String = {
        let session = "00000000-0000-0000-0000-000000000001"
        return """
        {"session_id": "\(session)", "ticker": "AAPL", "research": {"filings": [], "news": []}, "analysis": {"technical": {"rsi": 55.0}, "narrative": "RSI is 55.", "confidence": "high"}, "risk_review": {"approved": true, "flags": [], "modified_response": "RSI is 55.", "disclaimer": "informational only"}, "disclaimer": "informational only"}
        """
    }()
}
