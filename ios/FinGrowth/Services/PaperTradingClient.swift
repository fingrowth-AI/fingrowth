import Foundation

// Plain JSON client for the FinGrowth paper-trading endpoints (P4-04).
//
// Separate from APIClient because the analysis route is SSE-shaped while this
// one is request/response — sharing the request-builder gave nothing but
// added an obscure code path. Both clients read the base URL from AppSettings
// so the user can point the simulator at localhost / a deployed backend.

enum PaperTradingClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case http(status: Int, message: String?)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let raw):
            return "The backend URL '\(raw)' is not valid. Update it in Settings."
        case .http(let status, let message):
            if let message, !message.isEmpty {
                return "Paper trading request failed (HTTP \(status)): \(message)"
            }
            return "Paper trading request failed (HTTP \(status))."
        case .decoding(let detail):
            return "The backend returned an unreadable response: \(detail)."
        case .network(let detail):
            return "Network error: \(detail)"
        }
    }
}

protocol PaperTradingService: Sendable {
    func listPositions() async throws -> [BrokerPosition]
    func listOrders(limit: Int, status: String) async throws -> [BrokerOrder]
    func placeOrder(_ request: PlacePaperOrderRequest) async throws -> BrokerOrder
    func benchmark(symbol: String, days: Int) async throws -> BenchmarkSeries
    func portfolioHistory(period: String, timeframe: String) async throws -> PortfolioHistorySeries
}

struct PlacePaperOrderRequest: Encodable, Sendable, Equatable {
    var ticker: String
    var quantity: Double
    var side: String  // "buy" | "sell"
    var orderType: String = "market"
    var timeInForce: String = "day"
}

// Envelopes matching the design-doc §7.3 contract: positions/orders are
// wrapped in a named key rather than returned as bare arrays.
private struct PositionsEnvelope: Decodable {
    let positions: [BrokerPosition]
}

private struct OrdersEnvelope: Decodable {
    let orders: [BrokerOrder]
}

final class PaperTradingClient: PaperTradingService {
    private let baseURLProvider: @Sendable () -> String
    private let tokenProvider: @Sendable () -> String
    private let session: URLSession

    init(
        baseURLProvider: @escaping @Sendable () -> String,
        tokenProvider: @escaping @Sendable () -> String = { APIClient.placeholderToken },
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURLProvider
        self.tokenProvider = tokenProvider
        self.session = session
    }

    convenience init(settings: AppSettings, session: URLSession = .shared) {
        // Placeholder token until V8 issues a real session token (V7-05); the
        // paper routes accept current_user, so every call is auth-shaped.
        self.init(
            baseURLProvider: { [weak settings] in
                settings?.backendURL ?? AppSettings.defaultBackendURL
            },
            tokenProvider: { APIClient.placeholderToken },
            session: session
        )
    }

    func listPositions() async throws -> [BrokerPosition] {
        let envelope: PositionsEnvelope = try await get("/api/v1/paper/positions")
        return envelope.positions
    }

    func listOrders(limit: Int = 50, status: String = "all") async throws -> [BrokerOrder] {
        var components = URLComponents(string: "/api/v1/paper/orders")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "status", value: status),
        ]
        let envelope: OrdersEnvelope = try await get(components.url!.relativeString)
        return envelope.orders
    }

    func placeOrder(_ request: PlacePaperOrderRequest) async throws -> BrokerOrder {
        try await post("/api/v1/paper/order", body: request)
    }

    func benchmark(symbol: String = "SPY", days: Int = 30) async throws -> BenchmarkSeries {
        var components = URLComponents(string: "/api/v1/paper/benchmark")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "days", value: String(days)),
        ]
        return try await get(components.url!.relativeString)
    }

    func portfolioHistory(
        period: String = "1M",
        timeframe: String = "1D"
    ) async throws -> PortfolioHistorySeries {
        var components = URLComponents(string: "/api/v1/paper/portfolio-history")!
        components.queryItems = [
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "timeframe", value: timeframe),
        ]
        return try await get(components.url!.relativeString)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = try buildRequest(path: path, method: "GET")
        return try await perform(request)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return try await perform(request)
    }

    private func buildRequest(path: String, method: String) throws -> URLRequest {
        let baseString = baseURLProvider()
        guard let baseURL = URL(string: baseString),
              let url = URL(string: path, relativeTo: baseURL)
        else {
            throw PaperTradingClientError.invalidBaseURL(baseString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // V7-05: every iOS API call is auth-shaped — always send the Bearer
        // header so V8's per-user trade partitioning is a fill, not a retrofit.
        request.setValue("Bearer \(tokenProvider())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PaperTradingClientError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PaperTradingClientError.network("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.detail
            throw PaperTradingClientError.http(status: http.statusCode, message: detail)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw PaperTradingClientError.decoding(error.localizedDescription)
        }
    }

    private struct ErrorEnvelope: Decodable {
        let detail: String?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
