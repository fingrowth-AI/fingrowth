import CryptoKit
import Foundation

// On-device model download + cache (P5-01).
//
// Downloads the Gemma 4 E4B GGUF on first use, reporting progress, and caches
// it under Documents so it survives app restarts and is never re-downloaded.
// The actual byte transfer sits behind `ModelFileTransferring` so the
// cache/persistence logic is unit-testable without touching the network.

struct ModelDownloadProgress: Equatable, Sendable {
    var bytesWritten: Int64
    var totalBytes: Int64?
    /// 0...1, best-effort. `nil` total content length collapses to 0 until the
    /// transfer completes, at which point callers report 1.
    var fractionCompleted: Double
}

enum ModelDownloadError: LocalizedError, Equatable {
    case storageUnavailable
    case transferFailed(String)
    case badServerResponse(Int)
    case incompleteDownload
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Couldn't access on-device storage for the model."
        case .transferFailed(let detail):
            return "Model download failed: \(detail)."
        case .badServerResponse(let status):
            return "The model host returned an unexpected response (HTTP \(status))."
        case .incompleteDownload:
            return "The downloaded model was incomplete; please try again."
        case .checksumMismatch:
            return "The downloaded model failed integrity verification; please try again."
        }
    }
}

// Seam for the actual transfer. The real implementation streams bytes from the
// network; tests substitute a deterministic fake.
protocol ModelFileTransferring: Sendable {
    func transfer(
        from url: URL,
        to destination: URL,
        onProgress: @Sendable (ModelDownloadProgress) -> Void
    ) async throws
}

struct GemmaModelDownloader: Sendable {
    // Hugging Face GGUF for Gemma 4 E2B (Q3_K_S, ~2.45GB). Ungated unsloth
    // mirror, so the download needs no auth header. We run E2B at a small quant
    // rather than the E4B target because E4B (~4.5GB resident with full Metal
    // offload) is jetsam-killed under the default per-app memory limit, and the
    // increased-memory-limit entitlement can't be signed by a free Personal
    // Team. Bump to E4B Q4_K_M on a paid account. Overridable for tests/swaps.
    static let defaultModelURL = URL(
        string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q3_K_S.gguf"
    )!
    static let modelFileName = "gemma-4-e2b-it-q3_k_s.gguf"
    // Size floor for the default (real) model. The pinned GGUF is
    // 2,445,650,048 bytes; a 2.4GB lower bound rejects gross truncation. This
    // is only a cheap pre-check — `defaultExpectedSHA256` below is the
    // authoritative gate. Tests override with a small value.
    static let defaultMinimumValidBytes: Int64 = 2_400_000_000
    // Any floor at/above this is considered "tight enough" to gate a real
    // download in the absence of a checksum (see `hasStrongValidation`).
    static let strongValidationFloor: Int64 = 1_000_000_000
    // Published SHA-256 of unsloth/gemma-4-E2B-it-GGUF :: gemma-4-E2B-it-Q3_K_S.gguf
    // (HF LFS oid). Both freshly downloaded and cached copies are verified
    // against this, so a corrupt or substituted file is rejected.
    static let defaultExpectedSHA256: String? =
        "fce55e2ce5c7b8c96a9a4ea7dd9882ca6dd533edcfa50302526c4951d4e055ba"

    let modelURL: URL
    let cacheDirectory: URL
    let minimumValidBytes: Int64
    // Lowercase hex SHA-256 of the expected GGUF. When set, both freshly
    // downloaded and previously cached files are verified against it — the
    // authoritative integrity gate. `minimumValidBytes` is only a cheap floor
    // for when no digest is configured (e.g. the dev stub).
    let expectedSHA256: String?
    let transfer: ModelFileTransferring

    init(
        modelURL: URL = defaultModelURL,
        cacheDirectory: URL? = nil,
        minimumValidBytes: Int64 = defaultMinimumValidBytes,
        expectedSHA256: String? = defaultExpectedSHA256,
        transfer: ModelFileTransferring = URLSessionModelTransfer()
    ) throws {
        self.modelURL = modelURL
        self.cacheDirectory = try cacheDirectory ?? Self.defaultCacheDirectory()
        self.minimumValidBytes = minimumValidBytes
        self.expectedSHA256 = expectedSHA256?.lowercased()
        self.transfer = transfer
    }

    var cachedModelURL: URL {
        cacheDirectory.appending(path: Self.modelFileName)
    }

    /// Whether validation is strong enough to safely run a real download: a
    /// pinned checksum, or a size floor tight enough that a truncated response
    /// can't masquerade as the model. Guards against shipping a real download
    /// with only the cheap floor.
    var hasStrongValidation: Bool {
        expectedSHA256 != nil || minimumValidBytes >= Self.strongValidationFloor
    }

    /// A cached file counts as ready when it passes the size floor and, if a
    /// digest is configured, matches it. This is what lets the model persist
    /// across restarts without re-downloading — while still rejecting a stale
    /// truncated/corrupt file.
    func isModelCached() -> Bool {
        guard let size = cachedFileSize(), size >= minimumValidBytes else { return false }
        if let expectedSHA256 {
            return Self.sha256Hex(of: cachedModelURL) == expectedSHA256
        }
        return true
    }

    private func cachedFileSize() -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cachedModelURL.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    /// Returns the local model URL, downloading it first if not already cached.
    /// Downloads land in a `.partial` sidecar that is moved into place only on
    /// success, so an interrupted transfer is never mistaken for a cache hit.
    func ensureModel(
        onProgress: @Sendable (ModelDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        if isModelCached() {
            let size = cachedFileSize() ?? 0
            onProgress(ModelDownloadProgress(bytesWritten: size, totalBytes: size, fractionCompleted: 1))
            return cachedModelURL
        }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ModelDownloadError.storageUnavailable
        }

        let partialURL = cacheDirectory.appending(path: Self.modelFileName + ".partial")
        try? FileManager.default.removeItem(at: partialURL)

        do {
            try await transfer.transfer(from: modelURL, to: partialURL, onProgress: onProgress)
        } catch is CancellationError {
            // A cancelled download is not a failure — let it propagate so the
            // caller can settle on .notReady rather than .failed.
            try? FileManager.default.removeItem(at: partialURL)
            throw CancellationError()
        } catch let error as ModelDownloadError {
            // Preserve specific transfer-layer diagnoses (bad status, etc.).
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelDownloadError.transferFailed(error.localizedDescription)
        }

        // Size floor before promoting the partial to the canonical path.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
              let size = attrs[.size] as? Int64, size >= minimumValidBytes else {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelDownloadError.incompleteDownload
        }
        // Authoritative integrity check when a digest is configured.
        if let expectedSHA256, Self.sha256Hex(of: partialURL) != expectedSHA256 {
            try? FileManager.default.removeItem(at: partialURL)
            throw ModelDownloadError.checksumMismatch
        }

        try? FileManager.default.removeItem(at: cachedModelURL)
        do {
            try FileManager.default.moveItem(at: partialURL, to: cachedModelURL)
        } catch {
            throw ModelDownloadError.transferFailed(error.localizedDescription)
        }
        return cachedModelURL
    }

    // Streaming SHA-256 so a multi-GB file is never loaded into memory at once.
    // Returns nil if the file can't be read.
    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func defaultCacheDirectory() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docs.appending(path: "Models", directoryHint: .isDirectory)
    }
}

// MARK: - Real transfer

// Streams the model to disk in chunks so a multi-GB download never has to be
// held in memory, surfacing progress against the response's content length.
struct URLSessionModelTransfer: ModelFileTransferring {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transfer(
        from url: URL,
        to destination: URL,
        onProgress: @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(from: url)

        // Reject anything that isn't a clean 2xx before we write a byte — a
        // 404/redirect HTML page must never be mistaken for model weights.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelDownloadError.badServerResponse(http.statusCode)
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)  // flush every ~1MB

        for try await byte in bytes {
            buffer.append(byte)
            written += 1
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                onProgress(Self.progress(written: written, total: total))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        // A short read against a known Content-Length means the connection
        // dropped mid-stream — treat as incomplete rather than promoting a
        // truncated file.
        if let total, written != total {
            throw ModelDownloadError.incompleteDownload
        }
        onProgress(ModelDownloadProgress(bytesWritten: written, totalBytes: total, fractionCompleted: 1))
    }

    private static func progress(written: Int64, total: Int64?) -> ModelDownloadProgress {
        let fraction: Double
        if let total, total > 0 {
            fraction = min(1, Double(written) / Double(total))
        } else {
            fraction = 0
        }
        return ModelDownloadProgress(bytesWritten: written, totalBytes: total, fractionCompleted: fraction)
    }
}
