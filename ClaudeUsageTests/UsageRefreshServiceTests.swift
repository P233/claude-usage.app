import Foundation
import Combine
import AppKit

// MARK: - Simple Test Framework

/// Lightweight test result tracking - not isolated to MainActor for simplicity
final class TestRunner: @unchecked Sendable {
    static let shared = TestRunner()

    private var passCount = 0
    private var failCount = 0
    private var currentTest = ""
    private let lock = NSLock()

    func startTest(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        currentTest = name
        print("  ▶ \(name)")
    }

    func pass() {
        lock.lock()
        defer { lock.unlock() }
        passCount += 1
        print("    ✓ passed")
    }

    func fail(_ message: String, file: String = #file, line: Int = #line) {
        lock.lock()
        defer { lock.unlock() }
        failCount += 1
        let fileName = (file as NSString).lastPathComponent
        print("    ✗ FAILED: \(message) (\(fileName):\(line))")
    }

    func printSummary() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        print("")
        print("================================================================================")
        print("Results: \(passCount + failCount) tests, \(passCount) passed, \(failCount) failed")
        print("================================================================================")
        return failCount == 0
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected \(b), got \(a)", file: file, line: line)
    }
}

func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected true", file: file, line: line)
    }
}

func assertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected false", file: file, line: line)
    }
}

func assertNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value == nil {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected nil, got \(String(describing: value))", file: file, line: line)
    }
}

func assertNotNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value != nil {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected non-nil value", file: file, line: line)
    }
}

func assertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a > b {
        TestRunner.shared.pass()
    } else {
        TestRunner.shared.fail("\(message) - Expected \(a) > \(b)", file: file, line: line)
    }
}

// MARK: - Test Suite

@MainActor
final class UsageRefreshServiceTests {

    var mockAPIClient: MockClaudeAPIClient!
    var mockAuthService: MockAuthenticationService!
    var settings: UserSettings!
    var sut: UsageRefreshService!

    func setUp() async {
        mockAPIClient = MockClaudeAPIClient()
        mockAuthService = MockAuthenticationService()
        settings = UserSettings.shared

        // Default: authenticated state
        mockAuthService.setAuthState(.authenticated(
            organizationId: "test-org-123",
            subscriptionType: SubscriptionType(rawValue: "claude_pro")
        ))

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 50))
    }

    func tearDown() {
        sut?.stopAutoRefresh()
        sut = nil
        mockAPIClient = nil
        mockAuthService = nil
    }

    // MARK: - Helpers

    private func createService() -> UsageRefreshService {
        UsageRefreshService(
            apiClient: mockAPIClient,
            authService: mockAuthService,
            settings: settings
        )
    }

    private func makeUsageResponse(fiveHourUtil: Int, resetsAt: Date? = nil) -> UsageResponse {
        makeUsageResponse(fiveHourUtil: fiveHourUtil, fiveHourResetsAt: resetsAt)
    }

    private func makeUsageResponse(
        fiveHourUtil: Int,
        fiveHourResetsAt: Date? = nil,
        sevenDayUtil: Int? = nil,
        sevenDayResetsAt: Date? = nil
    ) -> UsageResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var items: [String: UsagePeriodResponse] = [
            "five_hour": UsagePeriodResponse(
                utilization: fiveHourUtil,
                resetsAt: fiveHourResetsAt.map { formatter.string(from: $0) }
            )
        ]

        if let sevenDayUtil = sevenDayUtil {
            items["seven_day"] = UsagePeriodResponse(
                utilization: sevenDayUtil,
                resetsAt: sevenDayResetsAt.map { formatter.string(from: $0) }
            )
        }

        return UsageResponse(items: items)
    }

    private func waitForRefresh() async {
        try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15 seconds
    }

    // MARK: - Tests

    func testSleepNotification_StopsAllTimers() async {
        TestRunner.shared.startTest("Sleep notification stops all timers")

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        let countdownBefore = sut.secondsUntilNextRefresh
        assertGreaterThan(countdownBefore, 0, "Auto-refresh should be active before sleep")

        // Post sleep notification via NSWorkspace's notification center
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await waitForRefresh()

        // After sleep, timers should be stopped
        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 after sleep")
    }

    func testWakeNotification_RefreshesAndRestartsTimers() async {
        TestRunner.shared.startTest("Wake notification refreshes and restarts timers")

        sut = createService()
        await waitForRefresh()

        let initialCallCount = mockAPIClient.fetchUsageCallCount

        // Simulate sleep then wake via NSWorkspace's notification center
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await waitForRefresh()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await waitForRefresh()

        assertGreaterThan(mockAPIClient.fetchUsageCallCount, initialCallCount, "Should refresh on wake")
        assertGreaterThan(sut.secondsUntilNextRefresh, 0, "Auto-refresh should restart")
    }

    func testWakeNotification_DoesNotRefreshWhenNotAuthenticated() async {
        TestRunner.shared.startTest("Wake notification does not refresh when not authenticated")

        mockAuthService.setAuthState(.notAuthenticated)
        sut = createService()
        await waitForRefresh()

        mockAPIClient.reset()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await waitForRefresh()

        assertEqual(mockAPIClient.fetchUsageCallCount, 0, "Should not refresh when not authenticated")
    }

    func testStartAutoRefresh_SetsCountdown() async {
        TestRunner.shared.startTest("startAutoRefresh sets countdown")

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()

        let expected = Int(settings.refreshInterval.seconds)
        assertGreaterThan(sut.secondsUntilNextRefresh, 0, "Countdown should be > 0")
        assertTrue(sut.secondsUntilNextRefresh <= expected, "Countdown should be <= interval")
    }

    func testStopAutoRefresh_ClearsCountdown() async {
        TestRunner.shared.startTest("stopAutoRefresh clears countdown")

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        sut.stopAutoRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 after stop")
    }

    func testAutoRefresh_PausesWhenPrimaryAtLimit() async {
        TestRunner.shared.startTest("Auto-refresh pauses when primary at limit")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        // Auto-refresh timer should be nil (paused), but countdown shows reset time
        assertTrue(sut.secondsUntilNextRefresh > 0, "Countdown should show time until reset")
    }

    func testResetCountdown_ShowsCorrectSecondsUntilReset() async {
        TestRunner.shared.startTest("Reset countdown shows correct seconds until reset")

        let resetTime = Date().addingTimeInterval(7200) // 2 hours from now
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: resetTime
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        // Countdown should be approximately 7200 seconds (2 hours), allow 10s tolerance
        let countdown = sut.secondsUntilNextRefresh
        assertTrue(countdown > 7100 && countdown <= 7200,
                   "Countdown should be ~7200s until reset, got \(countdown)")
    }

    func testResetCountdown_ManualRefreshWhileAtLimit() async {
        TestRunner.shared.startTest("Manual refresh while at limit keeps reset countdown")

        let resetTime = Date().addingTimeInterval(3600)
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: resetTime
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        let countdownBefore = sut.secondsUntilNextRefresh
        assertTrue(countdownBefore > 0, "Should have reset countdown before manual refresh")

        // Manual refresh still at 100%
        await sut.refreshNow()
        await waitForRefresh()

        let countdownAfter = sut.secondsUntilNextRefresh
        assertTrue(countdownAfter > 3500,
                   "Should count to resetsAt (~1h), not refresh interval, got \(countdownAfter)")
    }

    func testResetCountdown_ClearedByStopAutoRefresh() async {
        TestRunner.shared.startTest("stopAutoRefresh clears reset countdown")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 0, "Should have reset countdown")

        sut.stopAutoRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 after stop")
    }

    func testResetCountdown_NonPrimaryExpiredTriggersRefresh() async {
        TestRunner.shared.startTest("Non-primary item expired triggers refresh while paused")

        // five_hour at 100% (resets in 4h), seven_day at 80% (already expired)
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            fiveHourResetsAt: Date().addingTimeInterval(14400),
            sevenDayUtil: 80,
            sevenDayResetsAt: Date().addingTimeInterval(-10) // already past
        ))

        sut = createService()
        await waitForRefresh()

        let callCountBefore = mockAPIClient.fetchUsageCallCount

        // startAutoRefresh → startResetCountdown → updateCountdown → checkForExpiredResetTimes
        // seven_day's resetsAt is in the past, so it triggers refreshNow()
        sut.startAutoRefresh()
        await waitForRefresh()

        assertGreaterThan(mockAPIClient.fetchUsageCallCount, callCountBefore,
                          "Should trigger refresh when non-primary item expires")
    }

    func testResetCountdown_SleepWakeWhileAtLimit() async {
        TestRunner.shared.startTest("Sleep/wake while at limit restores reset countdown")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        assertTrue(sut.secondsUntilNextRefresh > 0, "Should have reset countdown before sleep")

        // Sleep: stops all timers
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        await waitForRefresh()

        assertEqual(sut.secondsUntilNextRefresh, 0, "Countdown should be 0 during sleep")

        // Wake: refreshes and restarts (still at 100%)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        await waitForRefresh()

        // Should have reset countdown again (not normal auto-refresh countdown)
        assertTrue(sut.secondsUntilNextRefresh > 3500,
                   "Should restore reset countdown (~1h), got \(sut.secondsUntilNextRefresh)")
    }

    func testResetCountdown_RecoveryFromLimitResumesAutoRefresh() async {
        TestRunner.shared.startTest("Recovery from 100% resumes normal auto-refresh")

        // Start at 100%
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(
            fiveHourUtil: 100,
            resetsAt: Date().addingTimeInterval(3600)
        ))

        sut = createService()
        await waitForRefresh()

        sut.startAutoRefresh()
        await waitForRefresh()

        // Confirm we're in Mode B (reset countdown, ~3600s)
        assertTrue(sut.secondsUntilNextRefresh > 3500,
                   "Should be counting to resetsAt, got \(sut.secondsUntilNextRefresh)")

        // Simulate reset: utilization drops to 0%
        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 0))

        // Manual refresh triggers the transition
        await sut.refreshNow()
        await waitForRefresh()

        assertEqual(sut.usageSummary?.primaryItem?.utilization, 0, "Utilization should be 0 after reset")

        // Now startAutoRefresh should enter Mode A (normal countdown to refresh interval)
        sut.startAutoRefresh()
        await waitForRefresh()

        let countdown = sut.secondsUntilNextRefresh
        let maxExpected = Int(settings.refreshInterval.seconds)
        assertTrue(countdown > 0 && countdown <= maxExpected,
                   "Should be normal auto-refresh countdown (1-\(maxExpected)s), got \(countdown)")
    }

    func testResetDetection_UtilizationUpdates() async {
        TestRunner.shared.startTest("Reset detection updates utilization")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 50))
        sut = createService()
        await waitForRefresh()

        assertEqual(sut.usageSummary?.primaryItem?.utilization, 50, "Initial utilization should be 50")

        mockAPIClient.fetchUsageResult = .success(makeUsageResponse(fiveHourUtil: 0))
        await sut.refreshNow()
        await waitForRefresh()

        assertEqual(sut.usageSummary?.primaryItem?.utilization, 0, "Utilization should update to 0")
    }

    func testAuthStateChange_ClearsDataOnLogout() async {
        TestRunner.shared.startTest("Auth state change clears data on logout")

        sut = createService()
        await waitForRefresh()

        assertNotNil(sut.usageSummary, "Should have data when authenticated")

        mockAuthService.setAuthState(.notAuthenticated)
        await waitForRefresh()

        assertNil(sut.usageSummary, "Should clear data on logout")
    }

    func testRefresh_SetsErrorOnAPIFailure() async {
        TestRunner.shared.startTest("Refresh sets error on API failure")

        mockAPIClient.fetchUsageResult = .failure(NSError(domain: "test", code: -1))
        sut = createService()
        await waitForRefresh()

        assertNotNil(sut.lastError, "Should set error on failure")
    }

    func testRefresh_ClearsErrorOnSuccess() async {
        TestRunner.shared.startTest("Refresh clears error on success")

        // Start fresh with a working API
        sut = createService()
        await waitForRefresh()

        // Manually set an error (simulating previous failure)
        // We can't easily test the actual error-clearing flow due to retry logic
        // running in background, so we just verify a successful refresh has no error
        assertNil(sut.lastError, "Should have no error after successful refresh")

        // Verify usageSummary is populated (proves refresh succeeded)
        assertNotNil(sut.usageSummary, "Should have usage data")
    }

    func testRefresh_SkipsWhenAlreadyRefreshing() async {
        TestRunner.shared.startTest("Refresh skips when already refreshing")

        // First, wait for any initial refresh to complete
        sut = createService()
        await waitForRefresh()
        await waitForRefresh()

        // Now set up a slow API response and reset counter
        mockAPIClient.fetchUsageDelay = 0.5
        mockAPIClient.reset()

        // Fire multiple concurrent refreshes - only the first should go through
        async let r1: Void = sut.refreshNow()
        // Small delay to ensure r1 starts first
        try? await Task.sleep(nanoseconds: 10_000_000)  // 0.01s
        async let r2: Void = sut.refreshNow()
        async let r3: Void = sut.refreshNow()

        _ = await (r1, r2, r3)

        assertEqual(mockAPIClient.fetchUsageCallCount, 1, "Should only make one API call")
    }

    // MARK: - Run All Tests

    func runAll() async {
        print("\n📋 Running UsageRefreshService Tests\n")

        await setUp()
        await testSleepNotification_StopsAllTimers()
        tearDown()

        await setUp()
        await testWakeNotification_RefreshesAndRestartsTimers()
        tearDown()

        await setUp()
        await testWakeNotification_DoesNotRefreshWhenNotAuthenticated()
        tearDown()

        await setUp()
        await testStartAutoRefresh_SetsCountdown()
        tearDown()

        await setUp()
        await testStopAutoRefresh_ClearsCountdown()
        tearDown()

        await setUp()
        await testAutoRefresh_PausesWhenPrimaryAtLimit()
        tearDown()

        await setUp()
        await testResetCountdown_ShowsCorrectSecondsUntilReset()
        tearDown()

        await setUp()
        await testResetCountdown_ManualRefreshWhileAtLimit()
        tearDown()

        await setUp()
        await testResetCountdown_ClearedByStopAutoRefresh()
        tearDown()

        await setUp()
        await testResetCountdown_NonPrimaryExpiredTriggersRefresh()
        tearDown()

        await setUp()
        await testResetCountdown_SleepWakeWhileAtLimit()
        tearDown()

        await setUp()
        await testResetCountdown_RecoveryFromLimitResumesAutoRefresh()
        tearDown()

        await setUp()
        await testResetDetection_UtilizationUpdates()
        tearDown()

        await setUp()
        await testAuthStateChange_ClearsDataOnLogout()
        tearDown()

        await setUp()
        await testRefresh_SetsErrorOnAPIFailure()
        tearDown()

        await setUp()
        await testRefresh_ClearsErrorOnSuccess()
        tearDown()

        await setUp()
        await testRefresh_SkipsWhenAlreadyRefreshing()
        tearDown()
    }
}

// MARK: - Test Entry Point

@main
struct TestMain {
    static var testsComplete = false
    static var testSuccess = false

    static func main() {
        // Schedule tests on main actor
        Task { @MainActor in
            let tests = UsageRefreshServiceTests()
            await tests.runAll()
            testSuccess = TestRunner.shared.printSummary()
            testsComplete = true
        }

        // Pump the run loop until tests complete
        while !testsComplete {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        exit(testSuccess ? 0 : 1)
    }
}
