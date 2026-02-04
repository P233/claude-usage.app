import Foundation
import Combine
import WebKit

/// Mock authentication service for testing UsageRefreshService
@MainActor
final class MockAuthenticationService: ObservableObject, AuthenticationServiceProtocol {

    @Published private(set) var authState: AuthState = .notAuthenticated
    var authStatePublisher: Published<AuthState>.Publisher { $authState }

    // MARK: - Test Control

    func setAuthState(_ state: AuthState) {
        authState = state
    }

    // MARK: - AuthenticationServiceProtocol

    func checkStoredCredentials() async {
        // No-op for tests
    }

    func extractCookiesFromWebView(_ webView: WKWebView) async -> [HTTPCookie] {
        return []
    }

    func saveSession(cookies: [HTTPCookie], organizationId: String, subscriptionType: SubscriptionType) async throws {
        authState = .authenticated(organizationId: organizationId, subscriptionType: subscriptionType)
    }

    nonisolated func getSessionCookies() -> [HTTPCookie]? {
        return nil
    }

    func logout() async {
        authState = .notAuthenticated
    }
}
