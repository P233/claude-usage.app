import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "AuthenticationService")

// MARK: - Protocol

@MainActor
protocol AuthenticationServiceProtocol: AnyObject {
    var authState: AuthState { get }
    var authStatePublisher: Published<AuthState>.Publisher { get }

    func checkStoredCredentials() async
    func getAccessToken() async throws -> String
    func handleSessionExpired()
}

// MARK: - Implementation

@MainActor
final class AuthenticationService: ObservableObject, AuthenticationServiceProtocol {

    @Published private(set) var authState: AuthState = .unknown
    var authStatePublisher: Published<AuthState>.Publisher { $authState }

    private let oauthTokenService: OAuthTokenServiceProtocol

    /// In-memory OAuth token cache (read from Claude Code's Keychain, never written back).
    /// Refreshed tokens are only cached for this app's lifetime. On next launch, we re-read
    /// from Claude Code's Keychain (which Claude Code itself keeps fresh). This means a
    /// startup refresh network call is expected if the stored token has expired — acceptable
    /// tradeoff to avoid writing to another app's Keychain entry.
    private var cachedOAuthTokens: OAuthTokens?
    private var cachedRefreshToken: String?

    init(
        oauthTokenService: OAuthTokenServiceProtocol = OAuthTokenService()
    ) {
        self.oauthTokenService = oauthTokenService
    }

    // MARK: - Credential Check

    func checkStoredCredentials() async {
        guard let credentials = oauthTokenService.loadClaudeCodeCredentials(),
              let oauthTokens = credentials.claudeAiOauth else {
            logger.info("No OAuth credentials found from Claude Code")
            authState = .notAuthenticated
            return
        }

        let subType = SubscriptionType.from(oauthSubscriptionType: oauthTokens.subscriptionType)
        let subscriptionType = subType.rawValue != nil
            ? subType
            : SubscriptionType.from(rateLimitTier: oauthTokens.rateLimitTier)

        cachedRefreshToken = oauthTokens.refreshToken

        if oauthTokens.isExpired {
            do {
                let refreshed = try await oauthTokenService.refreshAccessToken(refreshToken: oauthTokens.refreshToken)
                let expiresIn = refreshed.expiresIn ?? {
                    logger.warning("OAuth: server omitted expiresIn, defaulting to 3600s")
                    return 3600
                }()
                cachedOAuthTokens = OAuthTokens(
                    accessToken: refreshed.accessToken,
                    refreshToken: oauthTokens.refreshToken,
                    expiresAt: Int64((Date().timeIntervalSince1970 + Double(expiresIn)) * 1000),
                    scopes: oauthTokens.scopes,
                    subscriptionType: oauthTokens.subscriptionType,
                    rateLimitTier: oauthTokens.rateLimitTier
                )
                logger.info("OAuth: token refreshed successfully")
                authState = .authenticated(subscriptionType: subscriptionType)
            } catch {
                logger.warning("OAuth: token refresh failed: \(error.localizedDescription)")
                cachedOAuthTokens = nil
                cachedRefreshToken = nil
                authState = .notAuthenticated
            }
        } else {
            cachedOAuthTokens = oauthTokens
            logger.info("OAuth: authenticated via Claude Code credentials")
            authState = .authenticated(subscriptionType: subscriptionType)
        }
    }

    // MARK: - OAuth Access Token

    /// Returns a valid access token, refreshing if needed.
    func getAccessToken() async throws -> String {
        guard let tokens = cachedOAuthTokens else {
            throw ClaudeAPIClient.APIError.notAuthenticated
        }

        if !tokens.isExpired {
            return tokens.accessToken
        }

        // Token expired — try refresh
        guard let refreshToken = cachedRefreshToken else {
            throw ClaudeAPIClient.APIError.sessionExpired
        }

        let refreshed = try await oauthTokenService.refreshAccessToken(refreshToken: refreshToken)
        let expiresIn = refreshed.expiresIn ?? {
            logger.warning("OAuth: server omitted expiresIn, defaulting to 3600s")
            return 3600
        }()

        cachedOAuthTokens = OAuthTokens(
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            expiresAt: Int64((Date().timeIntervalSince1970 + Double(expiresIn)) * 1000),
            scopes: tokens.scopes,
            subscriptionType: tokens.subscriptionType,
            rateLimitTier: tokens.rateLimitTier
        )

        logger.info("OAuth: access token refreshed on demand")
        return refreshed.accessToken
    }

    // MARK: - Session Management

    /// Called when API returns 401/403 — session expired
    func handleSessionExpired() {
        logger.warning("Session expired, clearing credentials")
        cachedOAuthTokens = nil
        cachedRefreshToken = nil
        authState = .notAuthenticated
    }
}
