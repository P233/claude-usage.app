import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "UsageRefreshService")

@MainActor
protocol UsageRefreshServiceProtocol: AnyObject {
    var usageSummary: UsageSummary? { get }
    var usageSummaryPublisher: Published<UsageSummary?>.Publisher { get }
    var isRefreshing: Bool { get }
    var lastError: String? { get }
    var secondsUntilNextRefresh: Int { get }

    func startAutoRefresh()
    func stopAutoRefresh()
    func refreshNow() async
}

@MainActor
final class UsageRefreshService: ObservableObject, UsageRefreshServiceProtocol {

    @Published private(set) var usageSummary: UsageSummary?
    var usageSummaryPublisher: Published<UsageSummary?>.Publisher { $usageSummary }

    @Published private(set) var extraUsage: ExtraUsageSummary?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var secondsUntilNextRefresh: Int = 0

    private let apiClient: ClaudeAPIClientProtocol
    private let authService: AuthenticationServiceProtocol
    private let settings: UserSettings
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var nextRefreshDate: Date?
    private var retryCount = 0
    private let maxRetries = 3
    private var currentRefreshTask: Task<Void, Never>?

    private let cacheKey = "cachedUsageSummary_v2"

    /// Last known primary utilization percentage (0-100), used to detect reset.
    private var lastUtilization: Int?

    /// Timer to resume refresh when primary usage resets
    private var resumeRefreshTimer: Timer?

    /// Set of already-processed reset times to avoid triggering multiple refreshes
    private var processedResetTimes: Set<Date> = []

    /// Sleep/wake notification observers (must be removed on deinit)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Cached date formatters for performance
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        apiClient: ClaudeAPIClientProtocol,
        authService: AuthenticationServiceProtocol,
        settings: UserSettings? = nil
    ) {
        self.apiClient = apiClient
        self.authService = authService
        self.settings = settings ?? .shared

        loadCachedData()
        setupAuthStateObserver()
        setupSettingsObserver()
        setupWakeObserver()
    }

    deinit {
        currentRefreshTask?.cancel()
        refreshTimer?.invalidate()
        countdownTimer?.invalidate()
        resumeRefreshTimer?.invalidate()
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func setupAuthStateObserver() {
        authService.authStatePublisher
            .sink { [weak self] (state: AuthState) in
                guard let self = self else { return }

                // Cancel and wait for previous task to complete
                self.currentRefreshTask?.cancel()
                self.currentRefreshTask = nil
                self.retryCount = 0  // Reset retry count on auth state change

                if state.isAuthenticated {
                    self.currentRefreshTask = Task { [weak self] in
                        guard !Task.isCancelled else { return }
                        await self?.refreshNow()
                    }
                    self.startAutoRefresh()
                } else {
                    self.stopAllTimers()
                    self.usageSummary = nil
                    self.extraUsage = nil
                    self.clearCache()
                    self.lastUtilization = nil
                }
            }
            .store(in: &cancellables)
    }

    private func setupSettingsObserver() {
        settings.$refreshIntervalRaw
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.authService.authState.isAuthenticated {
                    self.startAutoRefresh()
                }
            }
            .store(in: &cancellables)
    }

    private func setupWakeObserver() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Stop all timers before sleep to prevent Power Nap from triggering
            // API requests or reset sounds. The Task executes on the main actor
            // before the system completes the sleep transition. The wake handler
            // also defensively cleans up resumeRefreshTimer as a safety net.
            Task { @MainActor in
                logger.info("System going to sleep, stopping all timers")
                self.stopAllTimers()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                guard self.authService.authState.isAuthenticated else { return }

                logger.info("System woke from sleep, refreshing usage")
                self.resumeRefreshTimer?.invalidate()
                self.resumeRefreshTimer = nil
                await self.refreshNow()
                self.startAutoRefresh()
            }
        }
    }

    /// Checks if primary usage has reset and plays notification sound.
    private func checkForResetAndPlaySound(utilization: Int?) {
        defer { lastUtilization = utilization }

        guard let current = utilization, let last = lastUtilization else { return }

        if last > 0 && current == 0 {
            logger.info("Primary usage reset detected (\(last)% → 0%), playing sound")
            settings.resetSound.play()
        }
    }

    /// Schedules a timer to resume refresh when primary usage resets.
    private func scheduleResumeRefresh(resetsAt: Date?) {
        resumeRefreshTimer?.invalidate()
        resumeRefreshTimer = nil

        guard let resetsAt = resetsAt else { return }

        let interval = resetsAt.timeIntervalSince(Date())
        guard interval > 0 else {
            logger.info("Reset time has passed, refreshing now")
            Task { @MainActor in
                await self.refreshNow()
            }
            return
        }

        let delayedInterval = interval + Constants.Refresh.resumeDelaySeconds

        logger.info("Primary usage expired, scheduling resume refresh in \(Int(delayedInterval))s")
        resumeRefreshTimer = Timer.scheduledTimer(withTimeInterval: delayedInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                logger.info("Resume timer fired, refreshing and restarting auto-refresh")
                await self.refreshNow()
                self.startAutoRefresh()
            }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()

        if let summary = usageSummary, summary.isPrimaryAtLimit {
            logger.info("Primary usage at limit, not starting auto-refresh")
            scheduleResumeRefresh(resetsAt: summary.primaryResetsAt)
            return
        }

        let interval = settings.refreshInterval.seconds
        nextRefreshDate = Date().addingTimeInterval(interval)
        updateCountdown()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.refreshNow()
                self.nextRefreshDate = Date().addingTimeInterval(self.settings.refreshInterval.seconds)
            }
        }

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCountdown()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        nextRefreshDate = nil
        secondsUntilNextRefresh = 0
    }

    private func stopAllTimers() {
        stopAutoRefresh()
        resumeRefreshTimer?.invalidate()
        resumeRefreshTimer = nil
    }

    private func updateCountdown() {
        guard let nextRefresh = nextRefreshDate else {
            secondsUntilNextRefresh = 0
            return
        }
        let remaining = Int(nextRefresh.timeIntervalSince(Date()))
        secondsUntilNextRefresh = max(0, remaining)

        // Check if any usage item's reset time has just expired
        checkForExpiredResetTimes()
    }

    /// Checks if any usage item's reset time has expired and triggers a refresh.
    private func checkForExpiredResetTimes() {
        guard !isRefreshing else { return }
        guard let items = usageSummary?.items else { return }

        let now = Date()
        for item in items {
            guard let resetsAt = item.resetsAt else { continue }

            // If resetsAt has expired and hasn't been processed yet
            if resetsAt <= now && !processedResetTimes.contains(resetsAt) {
                processedResetTimes.insert(resetsAt)
                logger.info("Usage item '\(item.key)' reset time expired, forcing refresh")
                Task { @MainActor in
                    await self.refreshNow()
                }
                return // Only trigger one refresh at a time
            }
        }
    }

    func refreshNow() async {
        guard !isRefreshing else {
            logger.debug("Refresh already in progress, skipping")
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Capture timer state before refresh to avoid race condition
        let hasActiveTimer = refreshTimer != nil
        let refreshInterval = settings.refreshInterval.seconds

        await performRefresh()

        // Only update next refresh date if timer was active before refresh
        if hasActiveTimer && refreshTimer != nil {
            nextRefreshDate = Date().addingTimeInterval(refreshInterval)
        }
    }

    private func performRefresh() async {
        guard let organizationId = authService.authState.organizationId else {
            lastError = "Not authenticated"
            return
        }

        if !NetworkMonitor.shared.isConnected {
            lastError = "No network connection"
            logger.warning("Refresh skipped: no network connection")
            return
        }

        lastError = nil

        do {
            let usageResponse = try await apiClient.fetchUsage(organizationId: organizationId)
            let summary = processUsageResponse(usageResponse)

            checkForResetAndPlaySound(utilization: summary.primaryItem?.utilization)

            self.usageSummary = summary
            self.retryCount = 0
            self.processedResetTimes.removeAll()
            saveCache(summary)

            if summary.isPrimaryAtLimit {
                logger.info("Primary usage at limit, pausing auto-refresh")
                stopAutoRefresh()
                scheduleResumeRefresh(resetsAt: summary.primaryResetsAt)
            }

            await fetchExtraUsageData(organizationId: organizationId)

            let primaryUtil = summary.primaryItem?.utilization ?? 0
            logger.info("Usage updated: \(summary.items.count) items, primary=\(primaryUtil)%")
        } catch let error as ClaudeAPIClient.APIError {
            lastError = error.localizedDescription
            logger.error("API Error: \(error.localizedDescription)")

            if error.isAuthError {
                retryCount = 0
            } else {
                await handleRetry(organizationId: organizationId)
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("Error: \(error.localizedDescription)")
            await handleRetry(organizationId: organizationId)
        }
    }

    private func handleRetry(organizationId: String) async {
        guard retryCount < maxRetries else {
            logger.warning("Max retries reached, waiting for next scheduled refresh")
            // Don't reset retryCount here - let it reset on successful refresh
            // This prevents rapid retry loops when network is consistently failing
            return
        }

        retryCount += 1
        // Exponential backoff: 30s, 60s, 120s
        let delay = Constants.Refresh.retryDelaySeconds * pow(2.0, Double(retryCount - 1))
        logger.info("Retrying in \(Int(delay))s (attempt \(self.retryCount)/\(self.maxRetries))")

        guard !Task.isCancelled else {
            logger.debug("Task cancelled, aborting retry")
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        guard !Task.isCancelled else {
            logger.debug("Task cancelled after sleep, aborting retry")
            return
        }

        await performRefresh()
    }

    // MARK: - Cache

    private func saveCache(_ summary: UsageSummary) {
        let cached = CachedUsageSummary(
            items: summary.items.map { CachedUsageItem(key: $0.key, utilization: $0.utilization, resetsAt: $0.resetsAt) },
            lastUpdated: summary.lastUpdated
        )

        do {
            let data = try JSONEncoder().encode(cached)
            UserDefaults.standard.set(data, forKey: cacheKey)
            logger.debug("Cache saved successfully")
        } catch {
            logger.warning("Failed to save cache: \(error.localizedDescription)")
        }
    }

    private static let cacheMaxAge: TimeInterval = 3600

    private func loadCachedData() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else {
            logger.debug("No cached data found")
            return
        }

        do {
            let cached = try JSONDecoder().decode(CachedUsageSummary.self, from: data)

            let age = Date().timeIntervalSince(cached.lastUpdated)
            if age > Self.cacheMaxAge {
                logger.info("Cache expired (age: \(Int(age))s), will refresh on login")
                clearCache()
                return
            }

            let items = cached.items.map { UsageItem(key: $0.key, utilization: $0.utilization, resetsAt: $0.resetsAt) }
            self.usageSummary = UsageSummary(items: items, lastUpdated: cached.lastUpdated)
            logger.info("Loaded cached data (age: \(Int(age))s)")
        } catch {
            logger.warning("Failed to load cache: \(error.localizedDescription)")
        }
    }

    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        logger.debug("Cache cleared")
    }

    // MARK: - Extra Usage

    private func fetchExtraUsageData(organizationId: String) async {
        do {
            async let creditsTask = apiClient.fetchPrepaidCredits(organizationId: organizationId)
            async let spendLimitTask = apiClient.fetchOverageSpendLimit(organizationId: organizationId)

            let (credits, spendLimit) = try await (creditsTask, spendLimitTask)
            self.extraUsage = ExtraUsageSummary(credits: credits, spendLimit: spendLimit)
        } catch {
            logger.debug("Extra usage fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Processing

    private func processUsageResponse(_ response: UsageResponse) -> UsageSummary {
        var items: [UsageItem] = []

        for key in response.orderedKeys {
            guard let period = response.items[key] else { continue }

            let resetsAt = parseDate(period.resetsAt)
            let item = UsageItem(key: key, utilization: period.utilization, resetsAt: resetsAt)
            items.append(item)
        }

        return UsageSummary(items: items, lastUpdated: Date())
    }

    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }

        if let date = Self.isoFormatterWithFractional.date(from: dateString) {
            return date
        }

        if let date = Self.isoFormatterWithoutFractional.date(from: dateString) {
            return date
        }

        logger.warning("Failed to parse date: \(dateString)")
        return nil
    }
}

// MARK: - Cache Model

private struct CachedUsageSummary: Codable {
    let items: [CachedUsageItem]
    let lastUpdated: Date
}

private struct CachedUsageItem: Codable {
    let key: String
    let utilization: Int
    let resetsAt: Date?
}
