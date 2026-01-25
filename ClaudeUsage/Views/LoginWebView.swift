import SwiftUI
import WebKit
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "LoginWebView")

struct LoginWebView: NSViewRepresentable {
    let onLoginSuccess: ([HTTPCookie]) -> Void
    let onLoginFailed: (Error) -> Void
    let onLoadingStateChanged: ((Bool) -> Void)?

    init(
        onLoginSuccess: @escaping ([HTTPCookie]) -> Void,
        onLoginFailed: @escaping (Error) -> Void,
        onLoadingStateChanged: ((Bool) -> Void)? = nil
    ) {
        self.onLoginSuccess = onLoginSuccess
        self.onLoginFailed = onLoginFailed
        self.onLoadingStateChanged = onLoadingStateChanged
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Use non-persistent data store for clean login sessions
        // This avoids state conflicts after logout
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        // Add URL observer
        context.coordinator.observeURL(webView)

        // Notify loading started
        onLoadingStateChanged?(true)

        // Load Claude login page
        let request = URLRequest(url: Constants.API.loginURL)
        webView.load(request)

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        private var urlObservation: NSKeyValueObservation?
        private var extractionWorkItem: DispatchWorkItem?

        /// State machine for cookie extraction process
        private enum ExtractionState {
            case idle
            case waitingForSync(detectedURL: URL)
            case extracting
            case completed
        }
        private var extractionState: ExtractionState = .idle

        // Valid domains for Claude authentication
        private static let validDomains = ["claude.ai"]

        // Success paths indicate user has logged in
        private static let successPaths: Set<String> = ["/chat", "/new", "/onboarding", "/settings"]

        // Failure paths indicate user is still in login flow
        private static let authFlowPaths: Set<String> = ["/login", "/oauth", "/signup", "/sso"]

        init(_ parent: LoginWebView) {
            self.parent = parent
        }

        func observeURL(_ webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
                guard let self = self,
                      let url = change.newValue as? URL else { return }

                self.checkLoginStatus(webView: webView, url: url)
            }
        }

        /// Validates that the URL host is exactly claude.ai (prevents spoofing)
        private func isValidClaudeDomain(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }

            // Must be exactly "claude.ai" - not "not-claude.ai" or "claude.ai.evil.com"
            return Self.validDomains.contains(host)
        }

        /// Check if user has successfully logged in based on URL
        private func isLoggedIn(_ url: URL) -> Bool {
            guard isValidClaudeDomain(url) else { return false }

            let path = url.path.lowercased()

            // Check if on a success page
            if Self.successPaths.contains(where: { path.hasPrefix($0) }) {
                return true
            }

            // Check if still in auth flow
            if Self.authFlowPaths.contains(where: { path.hasPrefix($0) }) {
                return false
            }

            // Root path (claude.ai/) also indicates success
            return path == "/" || path.isEmpty
        }

        private func checkLoginStatus(webView: WKWebView, url: URL) {
            logger.debug("URL changed to: \(url.absoluteString)")

            // Only proceed if in idle state and logged in
            guard case .idle = extractionState, isLoggedIn(url) else { return }

            extractionState = .waitingForSync(detectedURL: url)
            logger.info("Login detected! Waiting for cookie sync...")

            // Cancel any pending extraction
            extractionWorkItem?.cancel()

            // Wait for cookies to sync, then verify URL hasn't changed
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }

                // Verify state is still waiting for sync
                guard case .waitingForSync(let detectedURL) = self.extractionState else {
                    logger.debug("Extraction state changed, skipping")
                    return
                }

                // Verify we're still on a valid page (user didn't navigate away)
                guard let currentURL = webView.url, self.isLoggedIn(currentURL) else {
                    logger.warning("URL changed during cookie sync, resetting to idle")
                    self.extractionState = .idle
                    return
                }

                logger.info("Cookie sync complete, extracting from: \(detectedURL.absoluteString)")
                self.extractionState = .extracting
                self.extractCookies(from: webView)
            }

            extractionWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Login.cookieSyncDelay,
                execute: workItem
            )
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingStateChanged?(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingStateChanged?(false)
            guard let url = webView.url else { return }
            checkLoginStatus(webView: webView, url: url)
        }

        private func extractCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }

                logger.debug("Found \(cookies.count) total cookies")

                // Filter Claude.ai related cookies using secure domain validation
                let claudeCookies = cookies.filter { cookie in
                    Constants.Domain.isValidCookieDomain(cookie.domain)
                }

                logger.debug("Found \(claudeCookies.count) Claude cookies")
                for cookie in claudeCookies {
                    logger.debug("  - \(cookie.name): \(cookie.domain)")
                }

                DispatchQueue.main.async {
                    // Mark extraction as completed
                    self.extractionState = .completed

                    if claudeCookies.isEmpty {
                        self.parent.onLoginFailed(LoginError.noCookiesFound)
                    } else {
                        self.parent.onLoginSuccess(claudeCookies)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoginFailed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoginFailed(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }

        deinit {
            urlObservation?.invalidate()
            extractionWorkItem?.cancel()
        }
    }

    enum LoginError: Error, LocalizedError {
        case noCookiesFound

        var errorDescription: String? {
            switch self {
            case .noCookiesFound:
                return "No authentication cookies found. Please try logging in again."
            }
        }
    }
}
