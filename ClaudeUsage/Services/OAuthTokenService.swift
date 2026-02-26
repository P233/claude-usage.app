import Foundation
import Security
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "OAuthTokenService")

// MARK: - Protocol

protocol OAuthTokenServiceProtocol {
    /// Attempt to load OAuth credentials from Claude Code CLI's Keychain entry.
    /// Returns nil if Claude Code is not installed or has no stored credentials.
    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials?

    /// Refresh the access token using the refresh token.
    func refreshAccessToken(refreshToken: String) async throws -> OAuthTokenRefreshResponse
}

// MARK: - Implementation

final class OAuthTokenService: OAuthTokenServiceProtocol {

    // MARK: - Errors

    enum OAuthError: Error, LocalizedError {
        case refreshFailed(String)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .refreshFailed(let message):
                return "Token refresh failed: \(message)"
            case .networkError(let error):
                return "Network error during token refresh: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Properties

    private let session: URLSession

    // MARK: - Initialization

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Constants.API.requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Keychain Reading

    func loadClaudeCodeCredentials() -> ClaudeCodeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.OAuth.claudeCodeKeychainService,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            logger.debug("No Claude Code credentials found in Keychain")
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            logger.error("Failed to read Claude Code Keychain entry: \(status)")
            return nil
        }

        do {
            let credentials = try JSONDecoder().decode(ClaudeCodeCredentials.self, from: data)
            logger.info("Successfully loaded Claude Code credentials")
            return credentials
        } catch {
            logger.error("Failed to decode Claude Code credentials: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Token Refresh

    func refreshAccessToken(refreshToken: String) async throws -> OAuthTokenRefreshResponse {
        var request = URLRequest(url: Constants.OAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Constants.OAuth.clientId
        ]
        request.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OAuthError.refreshFailed("Invalid response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                logger.error("Token refresh failed with HTTP \(httpResponse.statusCode)")
                throw OAuthError.refreshFailed("HTTP \(httpResponse.statusCode)")
            }

            let refreshResponse = try JSONDecoder().decode(OAuthTokenRefreshResponse.self, from: data)
            logger.info("OAuth token refreshed successfully")
            return refreshResponse
        } catch let error as OAuthError {
            throw error
        } catch let error as DecodingError {
            throw OAuthError.refreshFailed("Failed to decode response: \(error.localizedDescription)")
        } catch {
            throw OAuthError.networkError(error)
        }
    }
}
