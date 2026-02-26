import Foundation

/// Mock OAuth token service for testing
final class MockOAuthTokenService: OAuthTokenServiceProtocol {

    // MARK: - Configurable Behavior

    var credentials: ClaudeCodeCredentials?
    var refreshResult: Result<OAuthTokenRefreshResponse, Error> = .failure(MockError.notConfigured)

    // MARK: - Call Tracking

    private(set) var loadCredentialsCallCount = 0
    private(set) var refreshTokenCallCount = 0

    // MARK: - OAuthTokenServiceProtocol

    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials? {
        loadCredentialsCallCount += 1
        return credentials
    }

    func refreshAccessToken(refreshToken: String) async throws -> OAuthTokenRefreshResponse {
        refreshTokenCallCount += 1
        return try refreshResult.get()
    }

    // MARK: - Errors

    enum MockError: Error {
        case notConfigured
    }
}
