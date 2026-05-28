import XCTest
import CryptoKit
@testable import FinGrowth

// Tests for P5-01 — on-device Gemma 4 integration.
//
// Acceptance criteria (verifiable here, on the stub path):
//   * generate(prompt:) streams text token-by-token
//   * classify(prompt:categories:) resolves to a single category
//   * model state machine downloads → loads → ready, with progress
//   * cached model persists across "restarts" without re-download
//
// The device-only criteria (loads on iPhone 15/16 without OOM, <5s inference,
// main thread never blocked) require real hardware + the swift-llama.cpp
// package and are exercised through the same protocol seam on-device.
final class GemmaServiceTests: XCTestCase {

    // MARK: - Downloader: cache + persistence

    func testIsModelCachedRespectsSizeThreshold() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 10,
            expectedSHA256: nil,  // size-threshold test only — opt out of the production checksum
            transfer: RecordingTransfer(bytes: 0)
        )
        XCTAssertFalse(downloader.isModelCached(), "no file yet")

        // Below threshold → not a usable cache.
        try Data(count: 4).write(to: downloader.cachedModelURL)
        XCTAssertFalse(downloader.isModelCached())

        // At/above threshold → cached.
        try Data(count: 16).write(to: downloader.cachedModelURL)
        XCTAssertTrue(downloader.isModelCached())
    }

    func testEnsureModelDownloadsThenReusesCacheAcrossRestarts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transfer = RecordingTransfer(bytes: 64)
        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: nil,  // cache-reuse test only — opt out of the production checksum
            transfer: transfer
        )

        let fraction = FractionBox()
        let url = try await downloader.ensureModel { progress in
            fraction.set(progress.fractionCompleted)
        }
        XCTAssertEqual(url, downloader.cachedModelURL)
        var calls = await transfer.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fraction.value, 1, accuracy: 0.0001)

        // Simulate a restart: a fresh downloader over the same directory must
        // reuse the cached file and never transfer again.
        let restarted = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: nil,
            transfer: transfer
        )
        XCTAssertTrue(restarted.isModelCached())
        _ = try await restarted.ensureModel()
        calls = await transfer.calls
        XCTAssertEqual(calls, 1, "cached model must not re-download")
    }

    func testEnsureModelPropagatesCancellation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            transfer: SlowTransfer(bytes: 32, delay: .seconds(10))
        )
        let task = Task { try await downloader.ensureModel() }
        try await Task.sleep(for: .milliseconds(50))  // let it enter the transfer
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Correct: cancellation is not rewrapped as .transferFailed.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(downloader.isModelCached(), "partial must be cleaned up on cancel")
    }

    func testEnsureModelRejectsChecksumMismatch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: "deadbeef",
            transfer: RecordingTransfer(bytes: 32)
        )
        do {
            _ = try await downloader.ensureModel()
            XCTFail("expected checksumMismatch")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertFalse(downloader.isModelCached(), "mismatched file must not be promoted")
    }

    func testEnsureModelAcceptsMatchingChecksum() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = 64
        let expected = SHA256.hash(data: Data(count: bytes))
            .map { String(format: "%02x", $0) }.joined()
        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: expected,
            transfer: RecordingTransfer(bytes: bytes)
        )
        let url = try await downloader.ensureModel()
        XCTAssertEqual(url, downloader.cachedModelURL)
        XCTAssertTrue(downloader.isModelCached(), "matching checksum should be a valid cache")
    }

    func testEnsureModelRejectsIncompleteDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Transfer writes fewer bytes than the threshold → incomplete.
        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 1_000,
            transfer: RecordingTransfer(bytes: 10)
        )
        do {
            _ = try await downloader.ensureModel()
            XCTFail("expected incompleteDownload")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .incompleteDownload)
        }
        XCTAssertFalse(downloader.isModelCached(), "partial file must not be promoted")
    }

    // MARK: - GemmaService: generate

    @MainActor
    func testGenerateStreamsTokens() async {
        let service = GemmaService(
            backend: StubLlamaBackend(responder: { _ in "alpha beta gamma" }),
            downloader: nil
        )
        var tokens: [String] = []
        for await token in service.generate(prompt: "hi") {
            tokens.append(token)
        }
        XCTAssertEqual(tokens.count, 3, "one delta per whitespace token")
        XCTAssertEqual(tokens.joined(), "alpha beta gamma")
    }

    @MainActor
    func testGenerateRespectsMaxTokens() async {
        let service = GemmaService(
            backend: StubLlamaBackend(responder: { _ in "one two three four five" }),
            downloader: nil
        )
        var count = 0
        for await _ in service.generate(prompt: "hi", maxTokens: 2) {
            count += 1
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - GemmaService: classify

    @MainActor
    func testClassifyExactMatch() async {
        let service = GemmaService(
            backend: StubLlamaBackend(responder: { _ in "technical" }),
            downloader: nil
        )
        let result = await service.classify(
            prompt: "Is AAPL overbought?",
            categories: ["fundamental", "technical", "general"]
        )
        XCTAssertEqual(result, "technical")
    }

    @MainActor
    func testClassifyFuzzyMatchFromChattyOutput() async {
        let service = GemmaService(
            backend: StubLlamaBackend(responder: { _ in "This looks Technical to me" }),
            downloader: nil
        )
        let result = await service.classify(
            prompt: "RSI is 80",
            categories: ["fundamental", "technical", "general"]
        )
        XCTAssertEqual(result, "technical")
    }

    @MainActor
    func testClassifyReturnsEmptyOnNoMatch() async {
        let service = GemmaService(
            backend: StubLlamaBackend(responder: { _ in "wholly unrelated noise" }),
            downloader: nil
        )
        let result = await service.classify(
            prompt: "?",
            categories: ["fundamental", "technical", "general"]
        )
        // No match must be reported as undetermined ("") — never a guessed
        // first category, which would turn a failure into a confident wrong
        // answer (and false PII detections downstream).
        XCTAssertEqual(result, "")
    }

    func testMatchCategoryRules() {
        let cats = ["fundamental", "technical", "general"]
        XCTAssertEqual(GemmaService.matchCategory("Technical", in: cats), "technical")
        XCTAssertEqual(GemmaService.matchCategory("it is technical analysis", in: cats), "technical")
        XCTAssertNil(GemmaService.matchCategory("", in: cats))
        XCTAssertNil(GemmaService.matchCategory("nonsense", in: cats))
    }

    // MARK: - GemmaService: state machine

    @MainActor
    func testPrepareWithStubBecomesReadyWithoutDownload() async {
        let service = GemmaService(backend: StubLlamaBackend(), downloader: nil)
        await service.prepare()
        XCTAssertEqual(service.state, .ready)
        XCTAssertTrue(service.isReady)
    }

    @MainActor
    func testPrepareWithFileBackendDownloadsLoadsAndBecomesReady() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = MockFileBackend()
        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: sha256Hex(ofZeroBytes: 32),
            transfer: RecordingTransfer(bytes: 32)
        )
        let service = GemmaService(backend: backend, downloader: downloader)

        await service.prepare()

        XCTAssertEqual(service.state, .ready)
        let loaded = await backend.loadedURL
        XCTAssertEqual(loaded, downloader.cachedModelURL, "the downloaded model should be loaded")
    }

    @MainActor
    func testConcurrentPrepareSharesOneDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transfer = SlowTransfer(bytes: 32, delay: .milliseconds(100))
        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: sha256Hex(ofZeroBytes: 32),
            transfer: transfer
        )
        let service = GemmaService(backend: MockFileBackend(), downloader: downloader)

        // Two concurrent prepares (e.g. launch + a Settings retry) must join the
        // same in-flight transfer, not cancel and restart the 2.5GB download.
        async let first: Void = service.prepare()
        async let second: Void = service.prepare()
        _ = await (first, second)

        XCTAssertEqual(service.state, .ready)
        let calls = await transfer.calls
        XCTAssertEqual(calls, 1, "concurrent prepares must not restart the download")
    }

    @MainActor
    func testCancelPreparationSettlesNotReady() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: sha256Hex(ofZeroBytes: 32),
            transfer: SlowTransfer(bytes: 32, delay: .seconds(10))
        )
        let service = GemmaService(backend: MockFileBackend(), downloader: downloader)

        let task = Task { await service.prepare() }
        // Wait until the download is in-flight.
        var waited = 0
        while service.state == .notReady, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        service.cancelPreparation()
        _ = await task.value

        XCTAssertEqual(service.state, .notReady, "cancellation must settle as .notReady, not .failed")
    }

    @MainActor
    func testPrepareRefusesRealDownloadWithoutStrongValidation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Weak validation: tiny floor, no checksum. The real path must refuse
        // rather than fetch an unverifiable 2.5GB file.
        let transfer = RecordingTransfer(bytes: 32)
        let downloader = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: 8,
            expectedSHA256: nil,
            transfer: transfer
        )
        let backend = MockFileBackend()
        let service = GemmaService(backend: backend, downloader: downloader)

        await service.prepare()

        guard case .failed = service.state else {
            return XCTFail("expected .failed, got \(service.state)")
        }
        let calls = await transfer.calls
        XCTAssertEqual(calls, 0, "must not download with weak validation")
        let loaded = await backend.loadedURL
        XCTAssertNil(loaded)
    }

    func testHasStrongValidation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let weak = try GemmaModelDownloader(
            cacheDirectory: dir, minimumValidBytes: 8, expectedSHA256: nil, transfer: RecordingTransfer(bytes: 0)
        )
        XCTAssertFalse(weak.hasStrongValidation)

        let bySize = try GemmaModelDownloader(
            cacheDirectory: dir,
            minimumValidBytes: GemmaModelDownloader.strongValidationFloor,
            transfer: RecordingTransfer(bytes: 0)
        )
        XCTAssertTrue(bySize.hasStrongValidation)

        let byChecksum = try GemmaModelDownloader(
            cacheDirectory: dir, minimumValidBytes: 8, expectedSHA256: "abc", transfer: RecordingTransfer(bytes: 0)
        )
        XCTAssertTrue(byChecksum.hasStrongValidation)
    }

    // MARK: - Helpers

    // SHA-256 of `count` zero bytes — matches what RecordingTransfer/SlowTransfer
    // write, so a downloader configured with it passes both the strong-validation
    // gate and the checksum check.
    private func sha256Hex(ofZeroBytes count: Int) -> String {
        SHA256.hash(data: Data(count: count)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "GemmaServiceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Test doubles

private actor RecordingTransfer: ModelFileTransferring {
    let bytes: Int
    private(set) var calls = 0

    init(bytes: Int) { self.bytes = bytes }

    func transfer(
        from url: URL,
        to destination: URL,
        onProgress: @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        calls += 1
        try Data(count: bytes).write(to: destination)
        onProgress(ModelDownloadProgress(
            bytesWritten: Int64(bytes),
            totalBytes: Int64(bytes),
            fractionCompleted: 1
        ))
    }
}

// Delays before writing so cancellation / concurrency windows are observable.
// Task.sleep throws CancellationError on cancel, exercising the passthrough.
private actor SlowTransfer: ModelFileTransferring {
    let bytes: Int
    let delay: Duration
    private(set) var calls = 0

    init(bytes: Int, delay: Duration) {
        self.bytes = bytes
        self.delay = delay
    }

    func transfer(
        from url: URL,
        to destination: URL,
        onProgress: @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        calls += 1
        try await Task.sleep(for: delay)
        try Data(count: bytes).write(to: destination)
        onProgress(ModelDownloadProgress(
            bytesWritten: Int64(bytes),
            totalBytes: Int64(bytes),
            fractionCompleted: 1
        ))
    }
}

// Thread-safe collector for the @Sendable progress callback.
private final class FractionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double = 0
    var value: Double { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ newValue: Double) { lock.lock(); _value = newValue; lock.unlock() }
}

// File-requiring backend so the download→load→ready path is exercised.
private actor MockFileBackend: LlamaInferenceBackend {
    private(set) var loadedURL: URL?

    nonisolated var requiresModelFile: Bool { true }

    func loadModel(at url: URL) async throws { loadedURL = url }
    func unloadModel() async { loadedURL = nil }
    func isModelLoaded() async -> Bool { loadedURL != nil }

    nonisolated func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
