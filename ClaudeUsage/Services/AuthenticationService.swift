import Foundation
import WebKit
import Combine
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "AuthenticationService")

// Thread-safe cookie storage
final class CookieStorage: @unchecked Sendable {
    private var cookies: [HTTPCookie]?
    private let lock = NSLock()

    func get() -> [HTTPCookie]? {
        lock.lock()
        defer { lock.unlock() }
        return cookies
    }

    func set(_ newCookies: [HTTPCookie]?) {
        lock.lock()
        defer { lock.unlock() }
        cookies = newCookies
    }
}

@MainActor
protocol AuthenticationServiceProtocol: AnyObject {
    var authState: AuthState { get }
    var authStatePublisher: Published<AuthState>.Publisher { get }

    func checkStoredCredentials() async
    func extractCookiesFromWebView(_ webView: WKWebView) async -> [HTTPCookie]
    func saveSession(cookies: [HTTPCookie], organizationId: String, subscriptionType: SubscriptionType) async throws
    nonisolated func getSessionCookies() -> [HTTPCookie]?
    func logout() async
}

@MainActor
final class AuthenticationService: ObservableObject, AuthenticationServiceProtocol {

    @Published private(set) var authState: AuthState = .unknown
    var authStatePublisher: Published<AuthState>.Publisher { $authState }

    private let keychainService: KeychainServiceProtocol
    private let cookieStorage = CookieStorage()

    // Known session cookie names used by Claude.ai
    private static let sessionCookieNames: Set<String> = [
        "sessionKey",
        "__Secure-next-auth.session-token",
        "lastActiveOrg"
    ]

    init(keychainService: KeychainServiceProtocol = KeychainService()) {
        self.keychainService = keychainService
    }

    func checkStoredCredentials() async {
        do {
            guard let credentials = try keychainService.loadCredentials() else {
                logger.info("No stored credentials found")
                authState = .notAuthenticated
                return
            }

            // Convert stored cookie data back to HTTPCookie objects
            // and filter out expired cookies
            let now = Date()
            let cookies = credentials.cookies.compactMap { cookieData -> HTTPCookie? in
                // Skip expired cookies
                if let expiresDate = cookieData.expiresDate, expiresDate < now {
                    logger.debug("Skipping expired cookie: \(cookieData.name)")
                    return nil
                }
                return cookieData.toHTTPCookie()
            }

            // Check if we have essential session cookies (not just any cookie with "session" in name)
            let hasValidSessionCookie = cookies.contains { cookie in
                Self.sessionCookieNames.contains(cookie.name)
            }

            if hasValidSessionCookie && !cookies.isEmpty {
                logger.info("Found valid session cookies, restoring session")
                cookieStorage.set(cookies)
                authState = .authenticated(
                    organizationId: credentials.organizationId,
                    subscriptionType: credentials.subscriptionType
                )
            } else {
                // Cookies expired or invalid, clear and require re-login
                logger.warning("No valid session cookies found, clearing credentials")
                try? keychainService.deleteCredentials()
                authState = .notAuthenticated
            }

        } catch {
            logger.error("Failed to load credentials: \(error.localizedDescription)")
            authState = .error("Failed to load credentials: \(error.localizedDescription)")
        }
    }

    func extractCookiesFromWebView(_ webView: WKWebView) async -> [HTTPCookie] {
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let claudeCookies = cookies.filter { Self.isValidCookieDomain($0.domain) }
                continuation.resume(returning: claudeCookies)
            }
        }
    }

    private static func isValidCookieDomain(_ domain: String) -> Bool {
        Constants.Domain.isValidCookieDomain(domain)
    }

    func saveSession(cookies: [HTTPCookie], organizationId: String, subscriptionType: SubscriptionType) async throws {
        let cookieDataArray = cookies.map { StoredCredentials.CookieData(from: $0) }

        let credentials = StoredCredentials(
            cookies: cookieDataArray,
            organizationId: organizationId,
            subscriptionType: subscriptionType,
            savedAt: Date()
        )

        try keychainService.save(credentials: credentials)
        cookieStorage.set(cookies)
        authState = .authenticated(organizationId: organizationId, subscriptionType: subscriptionType)
        logger.info("Session saved successfully")
    }

    nonisolated func getSessionCookies() -> [HTTPCookie]? {
        return cookieStorage.get()
    }

    func logout() async {
        logger.info("Logging out")
        try? keychainService.deleteCredentials()
        cookieStorage.set(nil)
        authState = .notAuthenticated
    }

    // Called when API returns 401 - session expired
    func handleSessionExpired() {
        logger.warning("Session expired, clearing credentials")
        cookieStorage.set(nil)
        try? keychainService.deleteCredentials()
        authState = .notAuthenticated
    }
}
