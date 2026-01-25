import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "ClaudeAPIClient")

protocol ClaudeAPIClientProtocol {
    func fetchBootstrap() async throws -> BootstrapResponse
    func fetchBootstrap(withCookies cookies: [HTTPCookie]) async throws -> BootstrapResponse
    func fetchUsage(organizationId: String) async throws -> UsageResponse
    func updateExtraUsage(organizationId: String, enabled: Bool) async throws
    func fetchPrepaidCredits(organizationId: String) async throws -> PrepaidCredits
    func fetchOverageSpendLimit(organizationId: String) async throws -> OverageSpendLimit
    func setupOverageBilling(organizationId: String, monthlyLimit: Int) async throws -> SetupOverageBillingResponse
}

final class ClaudeAPIClient: ClaudeAPIClientProtocol {

    enum APIError: Error, LocalizedError {
        case notAuthenticated
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int)
        case sessionExpired
        case decodingError(Error)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not authenticated. Please log in."
            case .invalidURL:
                return "Invalid URL"
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .sessionExpired:
                return "Session expired. Please log in again."
            case .decodingError(let error):
                return "Failed to parse response: \(error.localizedDescription)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }

        var isAuthError: Bool {
            switch self {
            case .notAuthenticated, .sessionExpired:
                return true
            default:
                return false
            }
        }
    }

    private let baseURL: URL
    private weak var authService: AuthenticationService?
    private let session: URLSession

    init(authService: AuthenticationService, baseURL: URL = Constants.API.baseURL) {
        self.authService = authService
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        // Disable automatic cookie handling since we manage cookies manually via headers
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = Constants.API.requestTimeout

        self.session = URLSession(configuration: config)
    }

    // MARK: - Request Building

    /// Configure common headers for all API requests
    private func configureHeaders(for request: inout URLRequest, cookies: [HTTPCookie]) {
        // Set cookies in header
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Required headers to mimic browser
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Constants.API.origin, forHTTPHeaderField: "Origin")
        request.setValue(Constants.API.referer, forHTTPHeaderField: "Referer")
        request.setValue(Constants.API.userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// Get session cookies or throw if not authenticated
    private func getRequiredCookies() throws -> [HTTPCookie] {
        guard let cookies = authService?.getSessionCookies(), !cookies.isEmpty else {
            throw APIError.notAuthenticated
        }
        return cookies
    }

    private func makeRequest(for endpoint: String, method: String = "GET") throws -> URLRequest {
        let cookies = try getRequiredCookies()
        return makeRequest(for: endpoint, method: method, cookies: cookies)
    }

    private func makeRequest(for endpoint: String, method: String = "GET", cookies: [HTTPCookie]) -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        configureHeaders(for: &request, cookies: cookies)
        return request
    }

    private func makeBootstrapRequest() throws -> URLRequest {
        let cookies = try getRequiredCookies()
        return makeBootstrapRequest(cookies: cookies)
    }

    private func makeBootstrapRequest(cookies: [HTTPCookie]) -> URLRequest {
        // Bootstrap endpoint uses query parameter for statsig hashing algorithm
        var components = URLComponents(url: baseURL.appendingPathComponent("bootstrap"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "statsig_hashing_algorithm", value: "djb2")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        configureHeaders(for: &request, cookies: cookies)
        return request
    }

    // MARK: - Response Handling

    private func handleResponse(_ response: URLResponse) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Handle 401/403 - session expired
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.warning("Session expired (HTTP \(httpResponse.statusCode))")
            await MainActor.run {
                authService?.handleSessionExpired()
            }
            throw APIError.sessionExpired
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error: \(httpResponse.statusCode)")
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        logger.debug("Request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")

        do {
            let (data, response) = try await session.data(for: request)
            try await handleResponse(response)

            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)

        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            logger.error("Decoding error: \(error.localizedDescription)")
            throw APIError.decodingError(error)
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
    }

    private func performRequestWithoutResponse(_ request: URLRequest) async throws {
        logger.debug("Request: \(request.httpMethod ?? "GET") \(request.url?.path ?? "")")

        do {
            let (_, response) = try await session.data(for: request)
            try await handleResponse(response)
        } catch let error as APIError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw APIError.networkError(error)
        }
    }

    // MARK: - API Methods

    func fetchBootstrap() async throws -> BootstrapResponse {
        let request = try makeBootstrapRequest()
        return try await performRequest(request)
    }

    func fetchBootstrap(withCookies cookies: [HTTPCookie]) async throws -> BootstrapResponse {
        let request = makeBootstrapRequest(cookies: cookies)
        return try await performRequest(request)
    }

    func fetchUsage(organizationId: String) async throws -> UsageResponse {
        let request = try makeRequest(for: "organizations/\(organizationId)/usage")
        return try await performRequest(request)
    }

    func updateExtraUsage(organizationId: String, enabled: Bool) async throws {
        var request = try makeRequest(for: "organizations/\(organizationId)/overage_spend_limit", method: "PUT")

        let body = UpdateOverageSpendLimitRequest(isEnabled: enabled)
        request.httpBody = try JSONEncoder().encode(body)

        try await performRequestWithoutResponse(request)
        logger.info("Extra usage updated: \(enabled)")
    }

    func fetchPrepaidCredits(organizationId: String) async throws -> PrepaidCredits {
        let request = try makeRequest(for: "organizations/\(organizationId)/prepaid/credits")
        return try await performRequest(request)
    }

    func fetchOverageSpendLimit(organizationId: String) async throws -> OverageSpendLimit {
        let request = try makeRequest(for: "organizations/\(organizationId)/overage_spend_limit")
        return try await performRequest(request)
    }

    func setupOverageBilling(organizationId: String, monthlyLimit: Int) async throws -> SetupOverageBillingResponse {
        var request = try makeRequest(for: "organizations/\(organizationId)/setup_overage_billing", method: "POST")

        let body = SetupOverageBillingRequest(
            seatTierMonthlySpendLimits: SeatTierLimits(teamStandard: nil, teamTier1: nil),
            orgMonthlySpendLimit: monthlyLimit
        )
        request.httpBody = try JSONEncoder().encode(body)

        return try await performRequest(request)
    }
}
