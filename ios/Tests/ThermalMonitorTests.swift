import XCTest
@testable import FinGrowth

// Tests for P5-02 — thermal management.
//
// Acceptance criteria (verifiable here):
//   * Token limit drops from 512 to 128 at .serious
//   * Queued requests resume when thermal returns to .nominal
//
// The "no thermal shutdown in a 20-minute session" criterion is a device
// runtime property; the queue-above-.serious + token-reduction policy below is
// the mechanism that enforces it.
final class ThermalMonitorTests: XCTestCase {

    // MARK: - Token budget

    @MainActor
    func testTokenBudgetByThermalState() {
        XCTAssertEqual(monitor(.nominal).recommendedMaxTokens(base: 512), 512)
        XCTAssertEqual(monitor(.fair).recommendedMaxTokens(base: 512), 512)
        // Acceptance: 512 → 128 at .serious.
        XCTAssertEqual(monitor(.serious).recommendedMaxTokens(base: 512), 128)
        XCTAssertEqual(monitor(.critical).recommendedMaxTokens(base: 512), 64)
    }

    @MainActor
    func testRecommendedTokensNeverExceedBase() {
        // A caller asking for fewer than the cap keeps their smaller request.
        XCTAssertEqual(monitor(.serious).recommendedMaxTokens(base: 32), 32)
    }

    // MARK: - Policy flags

    @MainActor
    func testThrottleAndQueueThresholds() {
        XCTAssertFalse(monitor(.nominal).isThrottling)
        XCTAssertFalse(monitor(.fair).isThrottling)
        XCTAssertTrue(monitor(.serious).isThrottling)
        XCTAssertTrue(monitor(.critical).isThrottling)

        // Queueing happens only *above* .serious.
        XCTAssertFalse(monitor(.serious).shouldQueueWork)
        XCTAssertTrue(monitor(.critical).shouldQueueWork)
    }

    @MainActor
    func testWarningMessagePresence() {
        XCTAssertNil(monitor(.nominal).warningMessage)
        XCTAssertNil(monitor(.fair).warningMessage)
        XCTAssertNotNil(monitor(.serious).warningMessage)
        XCTAssertNotNil(monitor(.critical).warningMessage)
    }

    // MARK: - Queue / resume

    @MainActor
    func testAwaitClearanceReturnsImmediatelyWhenNotCritical() async {
        // .serious throttles tokens but does not queue.
        await monitor(.serious).awaitClearance()  // must not hang
    }

    @MainActor
    func testAwaitClearanceQueuesUntilNominal() async {
        let mon = monitor(.critical)
        let resumed = ResumeFlag()
        let task = Task { @MainActor in
            await mon.awaitClearance()
            resumed.value = true
        }

        // Still queued while hot; cooling to .fair is not enough (must hit nominal).
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(resumed.value)
        mon.applyState(.fair)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(resumed.value, "should resume only at .nominal")

        mon.applyState(.nominal)
        await task.value
        XCTAssertTrue(resumed.value)
    }

    // MARK: - GemmaService integration

    @MainActor
    func testGenerateClampsTokensAtSerious() async {
        let backend = RecordingBackend()
        let service = GemmaService(
            backend: backend,
            downloader: nil,
            thermal: monitor(.serious)
        )
        for await _ in service.generate(prompt: "hi", maxTokens: 512) {}
        let cap = await backend.lastMaxTokens
        XCTAssertEqual(cap, 128, "tokens must be clamped to the .serious budget")
    }

    @MainActor
    func testGenerateQueuesAtCriticalAndResumesAtNominal() async {
        let backend = RecordingBackend()
        let mon = monitor(.critical)
        let service = GemmaService(backend: backend, downloader: nil, thermal: mon)

        let finished = ResumeFlag()
        let task = Task { @MainActor in
            for await _ in service.generate(prompt: "hi") {}
            finished.value = true
        }

        try? await Task.sleep(for: .milliseconds(40))
        var calls = await backend.callCount
        XCTAssertEqual(calls, 0, "must not run inference while critical")
        XCTAssertFalse(finished.value)

        mon.applyState(.nominal)
        await task.value
        calls = await backend.callCount
        XCTAssertEqual(calls, 1, "queued request resumes once cool")
    }

    @MainActor
    func testCancelledQueuedGenerationNeverRunsBackend() async {
        let backend = RecordingBackend()
        let mon = monitor(.critical)
        let service = GemmaService(backend: backend, downloader: nil, thermal: mon)

        let task = Task { @MainActor in
            for await _ in service.generate(prompt: "hi") {}
        }
        // Let the request park in the thermal queue, then cancel it.
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        // Cooling must not retroactively start the cancelled request.
        mon.applyState(.nominal)
        _ = await task.value
        try? await Task.sleep(for: .milliseconds(40))

        let calls = await backend.callCount
        XCTAssertEqual(calls, 0, "cancelled queued request must not start inference")
    }

    // MARK: - Helpers

    @MainActor
    private func monitor(_ state: ProcessInfo.ThermalState) -> ThermalMonitor {
        ThermalMonitor(observingNotifications: false, initialState: state)
    }
}

// Mutable flag for observing async completion from @MainActor tests.
@MainActor private final class ResumeFlag {
    var value = false
}

// Records the maxTokens it was asked for and how many times it ran.
private actor RecordingBackend: LlamaInferenceBackend {
    private(set) var lastMaxTokens: Int?
    private(set) var callCount = 0

    nonisolated var requiresModelFile: Bool { false }
    func loadModel(at url: URL) async throws {}
    func unloadModel() async {}
    func isModelLoaded() async -> Bool { true }

    private func record(maxTokens: Int) {
        lastMaxTokens = maxTokens
        callCount += 1
    }

    nonisolated func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(maxTokens: maxTokens)
                continuation.finish()
            }
        }
    }
}
