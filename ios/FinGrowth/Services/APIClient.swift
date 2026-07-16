import Foundation

// HTTP / SSE client for the FinGrowth backend (P4-02).
//
// streamAnalysis returns an AsyncThrowingStream<AnalysisEvent, Error> so views
// can `for try await` the pipeline's progress, partial_result, final_result,
// and error frames as they arrive. Cancelling the consuming task (or letting
// the AsyncThrowingStream go out of scope) tears down the underlying
// URLSession data task via the stream's onTermination handler.
//
// Reconnection: transient network failures mid-stream are retried with a
// short bounded backoff *only when no final_result has been observed yet*.
// Retrying after a terminal frame would needlessly re-run the LangGraph
// pipeline; surfacing the error post-final would surprise the UI.

// MARK: - Errors

enum APIClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case requestFailed(statusCode: Int)
    case network(message: String)
    case invalidEvent(detail: String)
    case server(message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "The backend URL '\(value)' is not valid. Update it in Settings."
        case .requestFailed(let code) where code == 401 || code == 403:
            return "The backend rejected this request (HTTP \(code)). Check your credentials in Settings."
        case .requestFailed(let code) where code == 429:
            return "You've reached the research request limit for now. Please try again later."
        case .requestFailed(let code) where (500..<600).contains(code):
            return "The backend is unavailable (HTTP \(code)). Please try again in a moment."
        case .requestFailed(let code):
            return "The backend returned an unexpected response (HTTP \(code))."
        case .network:
            return "Network error. Check your connection and try again."
        case .invalidEvent(let detail):
            return "The backend sent a response we couldn't read: \(detail)."
        case .server(let message):
            return "The backend reported an error: \(message)"
        case .cancelled:
            return "The request was cancelled."
        }
    }
}

// MARK: - Transport abstraction

// One-line-at-a-time view of a server-sent-events response. Abstracted so
// tests can replace URLSession with a deterministic line feeder without
// having to spin up a real HTTP server or wrestle with URLProtocol.
typealias SSELineStream = AsyncThrowingStream<String, Error>

protocol SSEByteStreamProviding: Sendable {
    func lineStream(for request: URLRequest) async throws -> (SSELineStream, HTTPURLResponse)
}

struct URLSessionSSETransport: SSEByteStreamProviding {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lineStream(
        for request: URLRequest
    ) async throws -> (SSELineStream, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.network(message: "missing HTTP response")
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (stream, http)
    }
}

// MARK: - APIClient

final class APIClient: Sendable {
    struct RetryPolicy: Sendable, Equatable {
        var maxAttempts: Int
        var initialBackoff: Duration
        var maxBackoff: Duration

        static let `default` = RetryPolicy(
            maxAttempts: 3,
            initialBackoff: .milliseconds(500),
            maxBackoff: .seconds(4)
        )

        static let none = RetryPolicy(
            maxAttempts: 1,
            initialBackoff: .zero,
            maxBackoff: .zero
        )
    }

    // V7-05: placeholder Bearer token sent until Sign in with Apple (V8)
    // issues a real session token. The backend tolerates any token (or none)
    // and resolves to the default user, but the client always sends the header
    // so the auth-shaped contract is exercised end to end.
    static let placeholderToken = "v7-placeholder-token"

    private let baseURLProvider: @Sendable () -> String
    private let tokenProvider: @Sendable () -> String
    private let transport: SSEByteStreamProviding
    private let retryPolicy: RetryPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void

    init(
        baseURLProvider: @escaping @Sendable () -> String,
        tokenProvider: @escaping @Sendable () -> String = { APIClient.placeholderToken },
        transport: SSEByteStreamProviding = URLSessionSSETransport(),
        retryPolicy: RetryPolicy = .default,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
    }

    convenience init(
        settings: AppSettings,
        sessionStore: SessionStore? = nil,
        transport: SSEByteStreamProviding = URLSessionSSETransport(),
        retryPolicy: RetryPolicy = .default
    ) {
        // AppSettings/SessionStore are @Observable; capture them weakly through
        // closures so APIClient itself stays Sendable. The Bearer token comes
        // from the signed-in session (V8-01), falling back to the placeholder
        // before sign-in.
        self.init(
            baseURLProvider: { [weak settings] in
                settings?.backendURL ?? AppSettings.defaultBackendURL
            },
            tokenProvider: { [weak sessionStore] in
                sessionStore?.token ?? APIClient.placeholderToken
            },
            transport: transport,
            retryPolicy: retryPolicy
        )
    }

    func streamAnalysis(
        query: AnalysisQuery,
        profile: PortfolioProfile? = nil
    ) -> AsyncThrowingStream<AnalysisEvent, Error> {
        AsyncThrowingStream<AnalysisEvent, Error> { continuation in
            let driver = Task { [self] in
                await self.driveStream(
                    query: query,
                    profile: profile,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                driver.cancel()
            }
        }
    }

    // MARK: - Internals

    private func driveStream(
        query: AnalysisQuery,
        profile: PortfolioProfile?,
        continuation: AsyncThrowingStream<AnalysisEvent, Error>.Continuation
    ) async {
        let request: URLRequest
        do {
            request = try buildRequest(query: query, profile: profile)
        } catch {
            continuation.finish(throwing: error)
            return
        }

        var attempt = 0
        var backoff = retryPolicy.initialBackoff
        var receivedFinal = false

        while attempt < retryPolicy.maxAttempts {
            attempt += 1
            do {
                // `onFinal` flips receivedFinal the instant the final_result is
                // yielded, *before* the stream finishes. If the line stream then
                // throws (e.g. the connection drops after the final frame but
                // before a clean close), the flag is already set, so the retry
                // logic below won't re-run an analysis we've already delivered.
                try await consume(
                    request: request,
                    continuation: continuation,
                    onFinal: { receivedFinal = true }
                )
                continuation.finish()
                return
            } catch is CancellationError {
                continuation.finish(throwing: APIClientError.cancelled)
                return
            } catch let error as APIClientError {
                // Non-retryable: bad URL, HTTP status, malformed payload.
                switch error {
                case .network:
                    if receivedFinal || attempt >= retryPolicy.maxAttempts {
                        continuation.finish(throwing: error)
                        return
                    }
                    // Fall through to backoff + retry.
                default:
                    continuation.finish(throwing: error)
                    return
                }
            } catch {
                // URLSession surfaces network drops as URLError; treat them
                // the same as our .network case for retry purposes.
                let mapped = APIClientError.network(message: error.localizedDescription)
                if receivedFinal || attempt >= retryPolicy.maxAttempts || !isRetryable(error) {
                    continuation.finish(throwing: mapped)
                    return
                }
            }

            do {
                try await sleeper(backoff)
            } catch {
                continuation.finish(throwing: APIClientError.cancelled)
                return
            }
            backoff = min(backoff * 2, retryPolicy.maxBackoff)
        }

        continuation.finish(throwing: APIClientError.network(
            message: "retry budget exhausted"
        ))
    }

    private func consume(
        request: URLRequest,
        continuation: AsyncThrowingStream<AnalysisEvent, Error>.Continuation,
        onFinal: () -> Void
    ) async throws {
        let (lines, response) = try await transport.lineStream(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIClientError.requestFailed(statusCode: response.statusCode)
        }

        var parser = SSEParser()
        for try await line in lines {
            try Task.checkCancellation()
            guard let frame = parser.consume(line: line) else { continue }
            let event = try decodeEvent(frame: frame)
            continuation.yield(event)
            if case .finalResult = event {
                onFinal()
            }
        }
        // Server may close the connection without a trailing blank line; flush.
        if let frame = parser.flush() {
            let event = try decodeEvent(frame: frame)
            continuation.yield(event)
            if case .finalResult = event {
                onFinal()
            }
        }
    }

    private func buildRequest(
        query: AnalysisQuery,
        profile: PortfolioProfile?
    ) throws -> URLRequest {
        let baseString = baseURLProvider()
        guard let baseURL = URL(string: baseString),
              let url = URL(string: "/api/v1/analysis/query", relativeTo: baseURL)
        else {
            throw APIClientError.invalidBaseURL(baseString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // V7-05: always send the Bearer header so the backend's auth contract is
        // exercised. The token is a placeholder until V8 issues a real one.
        request.setValue("Bearer \(tokenProvider())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let body = AnalysisRequestBody(
            query: query.query,
            ticker: query.ticker,
            analysisType: query.analysisType,
            sessionId: query.sessionId,
            portfolioProfile: profile
        )
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    private func decodeEvent(frame: SSEFrame) throws -> AnalysisEvent {
        let data = Data(frame.data.utf8)
        do {
            switch frame.event {
            case "progress":
                let payload = try Self.decoder.decode(StagePayload.self, from: data)
                return .progress(stage: payload.stage)
            case "partial_result":
                let envelope = try Self.decoder.decode(PartialEnvelope.self, from: data)
                switch envelope.stage {
                case "research":
                    let payload = try Self.decoder.decode(PartialResearchPayload.self, from: data)
                    return .partialResearch(payload.research)
                case "analysis":
                    let payload = try Self.decoder.decode(PartialAnalysisPayload.self, from: data)
                    return .partialAnalysis(
                        technical: payload.analysis.technical,
                        confidence: payload.analysis.confidence
                    )
                default:
                    throw APIClientError.invalidEvent(
                        detail: "unknown partial_result stage '\(envelope.stage)'"
                    )
                }
            case "final_result":
                let response = try Self.decoder.decode(AnalysisResponse.self, from: data)
                return .finalResult(response)
            case "error":
                let payload = try Self.decoder.decode(ErrorPayload.self, from: data)
                return .serverError(message: payload.message)
            default:
                throw APIClientError.invalidEvent(detail: "unknown event '\(frame.event)'")
            }
        } catch let error as APIClientError {
            throw error
        } catch {
            throw APIClientError.invalidEvent(
                detail: Self.decodeFailureDetail(
                    event: frame.event,
                    data: frame.data,
                    error: error
                )
            )
        }
    }

    private static func decodeFailureDetail(
        event: String,
        data: String,
        error: Error
    ) -> String {
        let prefix = String(data.prefix(220))
        return "\(event): \(describeDecodeError(error)). Payload starts: \(prefix)"
    }

    private static func describeDecodeError(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String {
            let value = keys.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "<root>" : value
        }

        if case DecodingError.keyNotFound(let key, let context) = error {
            return "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        }
        if case DecodingError.typeMismatch(let type, let context) = error {
            return "expected \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        }
        if case DecodingError.valueNotFound(let type, let context) = error {
            return "missing \(type) value at \(path(context.codingPath)): \(context.debugDescription)"
        }
        if case DecodingError.dataCorrupted(let context) = error {
            return "corrupt data at \(path(context.codingPath)): \(context.debugDescription)"
        }
        return error.localizedDescription
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

// MARK: - Wire structs (private to APIClient)

private struct AnalysisRequestBody: Encodable {
    let query: String
    let ticker: String
    let analysisType: AnalysisType
    let sessionId: UUID?
    let portfolioProfile: PortfolioProfile?
}

private struct StagePayload: Decodable {
    let stage: String
}

private struct PartialEnvelope: Decodable {
    let stage: String
}

private struct PartialResearchPayload: Decodable {
    let research: ResearchData
}

private struct PartialAnalysisPayload: Decodable {
    struct Inner: Decodable {
        let technical: [String: JSONValue]
        let confidence: String
    }
    let analysis: Inner
}

private struct ErrorPayload: Decodable {
    let message: String
}

// MARK: - SSE parser

struct SSEFrame: Equatable {
    var event: String
    var data: String
}

struct SSEParser {
    private var event: String?
    private var data: String = ""
    private var hasContent: Bool = false

    mutating func consume(line rawLine: String) -> SSEFrame? {
        // Strip a single trailing CR (CRLF line endings on the wire).
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") {
            return nil  // comment / keep-alive
        }
        guard let colon = line.firstIndex(of: ":") else {
            // Field name with no value — spec says treat as empty value.
            return nil
        }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }

        switch field {
        case "event":
            if hasContent {
                let frame = flush()
                event = value
                hasContent = true
                return frame
            }
            event = value
            hasContent = true
        case "data":
            if data.isEmpty {
                data = value
            } else {
                data += "\n" + value
            }
            hasContent = true
        case "id", "retry":
            break
        default:
            break
        }
        return nil
    }

    mutating func flush() -> SSEFrame? {
        guard hasContent else { return nil }
        let frame = SSEFrame(event: event ?? "message", data: data)
        event = nil
        data = ""
        hasContent = false
        return frame
    }
}
