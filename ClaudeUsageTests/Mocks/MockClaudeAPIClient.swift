import Foundation

/// Mock API client for testing UsageRefreshService
final class MockClaudeAPIClient: ClaudeAPIClientProtocol {

    // MARK: - Configurable Behavior

    var fetchUsageResult: Result<UsageResponse, Error> = .success(UsageResponse(items: [:]))
    var fetchBootstrapResult: Result<BootstrapResponse, Error>?
    var fetchPrepaidCreditsResult: Result<PrepaidCredits, Error>?
    var fetchOverageSpendLimitResult: Result<OverageSpendLimit, Error>?

    // MARK: - Call Tracking

    private(set) var fetchUsageCallCount = 0
    private(set) var fetchUsageOrganizationIds: [String] = []

    // MARK: - Artificial Delay

    var fetchUsageDelay: TimeInterval = 0

    // MARK: - ClaudeAPIClientProtocol

    func fetchBootstrap() async throws -> BootstrapResponse {
        if let result = fetchBootstrapResult {
            return try result.get()
        }
        throw MockError.notConfigured
    }

    func fetchBootstrap(withCookies cookies: [HTTPCookie]) async throws -> BootstrapResponse {
        try await fetchBootstrap()
    }

    func fetchUsage(organizationId: String) async throws -> UsageResponse {
        fetchUsageCallCount += 1
        fetchUsageOrganizationIds.append(organizationId)

        if fetchUsageDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(fetchUsageDelay * 1_000_000_000))
        }

        return try fetchUsageResult.get()
    }

    func updateExtraUsage(organizationId: String, enabled: Bool) async throws {
        // No-op for tests
    }

    func fetchPrepaidCredits(organizationId: String) async throws -> PrepaidCredits {
        if let result = fetchPrepaidCreditsResult {
            return try result.get()
        }
        throw MockError.notConfigured
    }

    func fetchOverageSpendLimit(organizationId: String) async throws -> OverageSpendLimit {
        if let result = fetchOverageSpendLimitResult {
            return try result.get()
        }
        throw MockError.notConfigured
    }

    func setupOverageBilling(organizationId: String, monthlyLimit: Int) async throws -> SetupOverageBillingResponse {
        throw MockError.notConfigured
    }

    // MARK: - Test Helpers

    func reset() {
        fetchUsageCallCount = 0
        fetchUsageOrganizationIds = []
    }

    enum MockError: Error {
        case notConfigured
    }
}
