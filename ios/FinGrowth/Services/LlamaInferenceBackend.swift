import Foundation

#if canImport(LlamaCpp)
import LlamaCpp
#endif

// Inference backend abstraction (P5-01).
//
// GemmaService talks only to this protocol so the heavyweight swift-llama.cpp
// binding stays isolated. The app builds and the test suite runs against a
// deterministic StubLlamaBackend; the real ~2.5GB GGUF model is wired in via
// LlamaCppBackend, which is compiled only when the SPM package is present
// (added to ios/project.yml and regenerated with xcodegen). That keeps every
// verifiable path green here while leaving a single drop-in seam for the
// on-device model.
protocol LlamaInferenceBackend: Sendable {
    /// Whether this backend needs GGUF weights on disk. The stub is a
    /// self-contained placeholder and returns false, so GemmaService skips the
    /// multi-GB download in the simulator / tests.
    var requiresModelFile: Bool { get }

    /// Load model weights from a local GGUF file. Throws if missing/unreadable.
    func loadModel(at url: URL) async throws

    func unloadModel() async

    func isModelLoaded() async -> Bool

    /// Token-by-token streaming generation. The stream finishes when the model
    /// emits its end-of-sequence token or `maxTokens` deltas have been yielded.
    func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}

enum LlamaBackendError: LocalizedError, Equatable {
    case modelFileMissing(URL)
    case modelNotLoaded
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelFileMissing(let url):
            return "Model file not found at \(url.lastPathComponent)."
        case .modelNotLoaded:
            return "The on-device model is not loaded yet."
        case .loadFailed(let detail):
            return "Failed to load the on-device model: \(detail)."
        }
    }
}

// MARK: - Deterministic stub (default in simulator + tests)

// Produces stable, offline output so the on-device pipeline can be exercised
// without the real model. Inference runs on a detached task to model the
// "never block the main thread" contract; `tokenDelay` lets tests observe
// incremental streaming and cancellation.
actor StubLlamaBackend: LlamaInferenceBackend {
    private var loaded = false
    private let tokenDelay: Duration
    private let responder: @Sendable (String) -> String

    init(
        tokenDelay: Duration = .zero,
        responder: @escaping @Sendable (String) -> String = StubLlamaBackend.defaultResponder
    ) {
        self.tokenDelay = tokenDelay
        self.responder = responder
    }

    nonisolated var requiresModelFile: Bool { false }

    func loadModel(at url: URL) async throws { loaded = true }
    func unloadModel() async { loaded = false }
    func isModelLoaded() async -> Bool { loaded }

    nonisolated func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        let responder = self.responder
        let tokenDelay = self.tokenDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                let text = responder(prompt)
                let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
                for (index, token) in tokens.enumerated() {
                    if Task.isCancelled { break }
                    if index >= maxTokens { break }
                    if tokenDelay != .zero { try? await Task.sleep(for: tokenDelay) }
                    let suffix = index == tokens.count - 1 ? "" : " "
                    continuation.yield(String(token) + suffix)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let defaultResponder: @Sendable (String) -> String = { _ in
        "On-device analysis is ready. This output is generated locally for "
            + "research purposes and is not financial advice."
    }
}

// MARK: - Real backend (compiled only with the swift-llama.cpp package)

#if canImport(LlamaCpp)
// Bridges GemmaService to swift-llama.cpp. Only compiled when the SPM package
// is linked, so it never affects the verifiable build here. The exact symbol
// names follow the chosen swift-llama.cpp distribution and may need adjusting
// when the package is added; the streaming shape (load weights, then emit
// token deltas until EOS / maxTokens) is what GemmaService relies on.
actor LlamaCppBackend: LlamaInferenceBackend {
    private var model: LlamaModel?
    private var context: LlamaContext?

    nonisolated var requiresModelFile: Bool { true }

    func loadModel(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LlamaBackendError.modelFileMissing(url)
        }
        do {
            let model = try LlamaModel(path: url.path)
            self.model = model
            self.context = try LlamaContext(model: model)
        } catch {
            throw LlamaBackendError.loadFailed(error.localizedDescription)
        }
    }

    func unloadModel() async {
        context = nil
        model = nil
    }

    func isModelLoaded() async -> Bool { context != nil }

    nonisolated func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let context = await self.context else {
                        throw LlamaBackendError.modelNotLoaded
                    }
                    try await context.evaluate(prompt: prompt)
                    var produced = 0
                    while produced < maxTokens, !Task.isCancelled {
                        guard let piece = try await context.nextToken() else { break }
                        continuation.yield(piece)
                        produced += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
