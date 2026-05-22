import Foundation
import Observation

// On-device Gemma 4 inference orchestrator (P5-01).
//
// Owns the model lifecycle (download → load → ready) and exposes the two
// primitives the privacy pipeline depends on:
//
//   * generate(prompt:) -> AsyncStream<String>   — token-by-token text
//   * classify(prompt:categories:) -> String     — pick one category
//
// Heavy inference happens in the injected LlamaInferenceBackend (an actor, off
// the main thread); GemmaService stays @MainActor only to publish observable
// state for the download UI. The default backend is the deterministic stub, so
// the app and tests run without the real ~2.5GB model; LlamaCppBackend takes
// over automatically once the swift-llama.cpp package is linked.
@MainActor
@Observable
final class GemmaService {
    enum ModelState: Equatable {
        case notReady
        case downloading(Double)  // fractionCompleted 0...1
        case loading
        case ready
        case failed(String)
    }

    static let shared = GemmaService()

    private(set) var state: ModelState = .notReady

    private let backend: LlamaInferenceBackend
    private let downloader: GemmaModelDownloader?
    private let defaultMaxTokens: Int
    private var prepareTask: Task<Void, Never>?

    init(
        backend: LlamaInferenceBackend = GemmaService.makeDefaultBackend(),
        downloader: GemmaModelDownloader? = try? GemmaModelDownloader(),
        defaultMaxTokens: Int = 512
    ) {
        self.backend = backend
        self.downloader = downloader
        self.defaultMaxTokens = defaultMaxTokens
    }

    nonisolated static func makeDefaultBackend() -> LlamaInferenceBackend {
        #if canImport(LlamaCpp)
        return LlamaCppBackend()
        #else
        return StubLlamaBackend()
        #endif
    }

    var isReady: Bool { state == .ready }

    /// True when the active backend is the real on-device Gemma model rather
    /// than the deterministic development stub. The UI uses this so a "Ready"
    /// stub isn't mistaken for a loaded 2.5GB model.
    var usesRealModel: Bool { backend.requiresModelFile }

    /// Progress for the download UI: 1 when ready, the live fraction while
    /// downloading, 0 otherwise.
    var preparationProgress: Double {
        switch state {
        case .ready: return 1
        case .downloading(let fraction): return fraction
        default: return 0
        }
    }

    // MARK: - Lifecycle

    /// Download (if needed) and load the model. Idempotent and safe to call on
    /// launch: concurrent callers join the *same* in-flight preparation rather
    /// than cancelling and restarting it — critical for the real path, where a
    /// restart would re-trigger the multi-GB transfer. Backends that need no
    /// weights (the stub) become ready instantly with no network traffic.
    func prepare() async {
        if case .ready = state { return }
        if let existing = prepareTask {
            await existing.value
            return
        }
        let task = Task { await runPrepare() }
        prepareTask = task
        await task.value
        // Clear so a later retry (e.g. after .failed) can start fresh. Safe on
        // @MainActor: this runs only after the single owning task completes.
        prepareTask = nil
    }

    func cancelPreparation() {
        prepareTask?.cancel()
        prepareTask = nil
        if case .ready = state { return }
        state = .notReady
    }

    private func runPrepare() async {
        do {
            guard backend.requiresModelFile else {
                // Deterministic stub: nothing to download or load.
                state = .ready
                return
            }
            guard let downloader else {
                state = .failed(ModelDownloadError.storageUnavailable.localizedDescription)
                return
            }
            // Fail safe rather than download a 2.5GB file we can't verify: the
            // real path requires a pinned checksum or a tight size floor.
            guard downloader.hasStrongValidation else {
                state = .failed(
                    "On-device model integrity isn't configured (set a checksum or a tighter expected size before enabling downloads)."
                )
                return
            }
            if await backend.isModelLoaded() {
                state = .ready
                return
            }

            state = .downloading(downloader.isModelCached() ? 1 : 0)
            let modelURL = try await downloader.ensureModel { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.state {
                        self.state = .downloading(progress.fractionCompleted)
                    }
                }
            }
            try Task.checkCancellation()

            state = .loading
            try await backend.loadModel(at: modelURL)
            state = .ready
        } catch is CancellationError {
            state = .notReady
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Inference

    /// Stream generated text token-by-token. Matches the design-doc signature
    /// (`-> AsyncStream<String>`). Iteration runs on a detached task so the main
    /// thread is never blocked; a backend error finishes the stream and flips
    /// `state` to `.failed`.
    func generate(prompt: String, maxTokens: Int? = nil) -> AsyncStream<String> {
        let cap = maxTokens ?? defaultMaxTokens
        let backend = self.backend
        return AsyncStream { continuation in
            let task = Task.detached {
                do {
                    for try await token in backend.generate(prompt: prompt, maxTokens: cap) {
                        continuation.yield(token)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.state = .failed(error.localizedDescription)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Classify `prompt` into exactly one of `categories`. Built on `generate`
    /// with a constrained instruction, then mapped to the closest category so a
    /// chatty model ("This looks Technical.") still resolves cleanly. Falls back
    /// to the first category when nothing matches.
    func classify(prompt: String, categories: [String]) async -> String {
        guard let first = categories.first else { return "" }
        let instruction = """
        Classify the text below into exactly one category.
        Categories: \(categories.joined(separator: ", ")).
        Reply with only the category name.

        Text: \(prompt)
        """
        var output = ""
        for await token in generate(prompt: instruction, maxTokens: 16) {
            output += token
        }
        return Self.matchCategory(output, in: categories) ?? first
    }

    /// Resolve raw model output to one of `categories`: exact match, then
    /// substring either direction, else nil.
    nonisolated static func matchCategory(_ raw: String, in categories: [String]) -> String? {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let exact = categories.first(where: { $0.lowercased() == normalized }) {
            return exact
        }
        if let contained = categories.first(where: { normalized.contains($0.lowercased()) }) {
            return contained
        }
        if let containing = categories.first(where: { $0.lowercased().contains(normalized) }) {
            return containing
        }
        return nil
    }
}
