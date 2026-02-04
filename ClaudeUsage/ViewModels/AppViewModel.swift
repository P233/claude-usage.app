import Foundation
import Combine
import SwiftUI
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "AppViewModel")

@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var authState: AuthState = .unknown
    @Published var usageSummary: UsageSummary?
    @Published var extraUsage: ExtraUsageSummary?
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var secondsUntilNextRefresh: Int = 0

    // MARK: - Services

    let authService: AuthenticationService
    let apiClient: ClaudeAPIClientProtocol
    let refreshService: UsageRefreshService
    var settings: UserSettings

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var menuBarTitle: String {
        guard let usage = usageSummary?.primaryItem else {
            return "–"
        }
        return "\(usage.utilization)%"
    }

    var statusColor: Color {
        guard let usage = usageSummary?.primaryItem else {
            return .secondary
        }
        return usage.statusLevel.color
    }

    var isExtraUsageEnabled: Bool {
        extraUsage?.spendLimit?.isEnabled ?? false
    }

    /// Whether the primary usage is at limit (paused auto-refresh)
    var isPrimaryAtLimit: Bool {
        usageSummary?.isPrimaryAtLimit ?? false
    }

    // MARK: - Initialization

    convenience init() {
        let settings = UserSettings.shared
        let authService = AuthenticationService()
        let apiClient = ClaudeAPIClient(authService: authService)
        let refreshService = UsageRefreshService(
            apiClient: apiClient,
            authService: authService,
            settings: settings
        )

        self.init(
            authService: authService,
            apiClient: apiClient,
            refreshService: refreshService,
            settings: settings
        )
    }

    init(
        authService: AuthenticationService,
        apiClient: ClaudeAPIClientProtocol,
        refreshService: UsageRefreshService,
        settings: UserSettings
    ) {
        self.authService = authService
        self.apiClient = apiClient
        self.refreshService = refreshService
        self.settings = settings

        setupBindings()
        logger.debug("AppViewModel initialized")

        Task { [weak self] in
            await self?.checkCredentialsOnLaunch()
        }
    }

    private func checkCredentialsOnLaunch() async {
        logger.debug("App launched, checking stored credentials")
        await authService.checkStoredCredentials()
    }

    private func setupBindings() {
        authService.$authState.assign(to: &$authState)
        refreshService.$usageSummary.assign(to: &$usageSummary)
        refreshService.$extraUsage.assign(to: &$extraUsage)
        refreshService.$isRefreshing.assign(to: &$isRefreshing)
        refreshService.$lastError.assign(to: &$lastError)
        refreshService.$secondsUntilNextRefresh.assign(to: &$secondsUntilNextRefresh)
    }

    // MARK: - Actions

    func logout() async {
        logger.info("User logging out")
        await authService.logout()
    }

    func refreshUsage() async {
        await refreshService.refreshNow()
    }

    func onLoginSuccess(cookies: [HTTPCookie]) async {
        lastError = nil
        logger.info("onLoginSuccess called with \(cookies.count) cookies")

        do {
            logger.info("Fetching bootstrap...")
            let bootstrap = try await apiClient.fetchBootstrap(withCookies: cookies)
            logger.info("Bootstrap fetched, hasValidAccount: \(bootstrap.hasValidAccount)")

            guard bootstrap.hasValidAccount, let organizationId = bootstrap.organizationId else {
                logger.error("No organization found in bootstrap response")
                lastError = "No organization found"
                authState = .error("No organization found")
                return
            }

            let subscriptionType = bootstrap.subscriptionType
            logger.info("Saving session...")

            try await authService.saveSession(
                cookies: cookies,
                organizationId: organizationId,
                subscriptionType: subscriptionType
            )

            // Immediately update local authState to avoid Combine async delay
            authState = .authenticated(organizationId: organizationId, subscriptionType: subscriptionType)

            logger.info("Login successful")
        } catch {
            logger.error("Failed to process login: \(error.localizedDescription)")
            lastError = error.localizedDescription
            authState = .error(error.localizedDescription)
        }
    }

    func quit() {
        logger.info("App quitting")
        NSApplication.shared.terminate(nil)
    }

    func toggleExtraUsage(enabled: Bool) async throws {
        guard let orgId = authState.organizationId else {
            logger.warning("Attempted to toggle extra usage while not authenticated")
            return
        }

        logger.info("Toggling extra usage to: \(enabled)")
        try await apiClient.updateExtraUsage(organizationId: orgId, enabled: enabled)
        await refreshService.refreshNow()
    }
}
