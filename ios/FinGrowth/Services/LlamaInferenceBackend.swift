import Foundation
import os

#if canImport(llama)
import llama
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

// MARK: - Real backend (compiled only with the llama.cpp XCFramework)

#if canImport(llama)
// Bridges GemmaService to the llama.cpp C API exposed by the `llama`
// XCFramework (built from upstream ggml-org/llama.cpp via build-xcframework.sh
// and linked through ios/project.yml). Compiled only when that package is
// present, so the deterministic stub path stays the default in CI/simulator.
//
// The C handles (model/context/vocab/sampler) are owned by this actor, which
// serializes all llama_* calls — none of them are thread-safe across contexts.
// Generation streams token pieces until the model emits an end-of-generation
// token or `maxTokens` deltas, honoring task cancellation between tokens.
actor LlamaCppBackend: LlamaInferenceBackend {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    // `llama_sampler` is a complete type in the headers, so Swift imports it as
    // a typed pointer (unlike the opaque model/context/vocab handles).
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    nonisolated var requiresModelFile: Bool { true }

    // Spike instrumentation (P5 real-model bring-up): load time + tokens/sec land
    // in the Xcode console / Console.app under subsystem com.fingrowth.FinGrowth,
    // category "llama".
    private static let log = Logger(subsystem: "com.fingrowth.FinGrowth", category: "llama")

    // ggml backend registration is process-global; run it exactly once.
    private static let backendInit: Void = { llama_backend_init() }()

    func loadModel(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LlamaBackendError.modelFileMissing(url)
        }
        _ = Self.backendInit
        let loadStart = Date()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99  // offload all layers to Metal on device

        guard let loadedModel = url.path.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            throw LlamaBackendError.loadFailed("llama_model_load_from_file returned null (unsupported architecture or corrupt GGUF?)")
        }

        var contextParams = llama_context_default_params()
        // Research prompts are short (classify/rewrite/recontextualize), so a
        // small window keeps the KV cache tiny — meaningful headroom on devices
        // without the increased-memory entitlement.
        contextParams.n_ctx = 2048
        contextParams.n_batch = 512
        guard let createdContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw LlamaBackendError.loadFailed("llama_init_from_model returned null")
        }

        // Greedy (argmax) sampling: deterministic, so a fixed prompt yields a
        // fixed completion — keeps the model path auditable like the rest of
        // the privacy pipeline.
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        model = loadedModel
        context = createdContext
        vocab = llama_model_get_vocab(loadedModel)
        sampler = chain
        Self.log.info("model loaded in \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms (n_ctx=\(llama_n_ctx(createdContext)))")
    }

    func unloadModel() async {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        vocab = nil
        model = nil
    }

    func isModelLoaded() async -> Bool { context != nil }

    nonisolated func generate(prompt: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.runGeneration(prompt: prompt, maxTokens: maxTokens, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runGeneration(
        prompt: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        guard let context, let vocab, let sampler else {
            continuation.finish(throwing: LlamaBackendError.modelNotLoaded)
            return
        }

        // Fresh KV state per call so one query's tokens never bleed into the
        // next — each classify/rewrite/recontextualize call is independent.
        llama_memory_clear(llama_get_memory(context), true)

        var tokens = [llama_token]()
        let tokenized = prompt.withCString { cstr -> Bool in
            let len = Int32(strlen(cstr))
            let needed = -llama_tokenize(vocab, cstr, len, nil, 0, true, true)
            guard needed > 0 else { return false }
            tokens = [llama_token](repeating: 0, count: Int(needed))
            let written = tokens.withUnsafeMutableBufferPointer {
                llama_tokenize(vocab, cstr, len, $0.baseAddress, Int32($0.count), true, true)
            }
            return written > 0
        }
        guard tokenized, !tokens.isEmpty else {
            continuation.finish()
            return
        }

        let promptStatus = tokens.withUnsafeMutableBufferPointer { buf -> Int32 in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard promptStatus == 0 else {
            continuation.finish(throwing: LlamaBackendError.loadFailed("prompt decode failed (\(promptStatus))"))
            return
        }

        let promptTokenCount = tokens.count
        let genStart = Date()
        var produced = 0
        while produced < maxTokens {
            if Task.isCancelled { break }
            let id = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, id) { break }
            if let piece = Self.piece(vocab: vocab, token: id), !piece.isEmpty {
                continuation.yield(piece)
            }
            var next = id
            let status = withUnsafeMutablePointer(to: &next) { ptr in
                llama_decode(context, llama_batch_get_one(ptr, 1))
            }
            if status != 0 { break }  // 1 = KV full, <0 = fatal; stop cleanly
            produced += 1
        }
        let elapsed = Date().timeIntervalSince(genStart)
        Self.log.info("gen: prompt=\(promptTokenCount) tok, produced=\(produced) tok in \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", Double(produced) / max(elapsed, 0.0001))) tok/s)")
        continuation.finish()
    }

    // Detokenize a single id to its UTF-8 text. `special: false` so control
    // tokens never render as literal text. Grows the buffer if a glyph needs
    // more than the initial 256 bytes.
    private static func piece(vocab: OpaquePointer, token: llama_token) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return n == 0 ? "" : nil }
        let bytes = buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
