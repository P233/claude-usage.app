import Foundation
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "UsageData")

// MARK: - Date Formatters (cached for performance)

private enum DateFormatters {
    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// Abbreviated duration formatter in English (e.g., "2h 30m", "3d 5h")
    static let remainingTime: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: "en_US_POSIX")
            return calendar
        }()
        return formatter
    }()
}

// MARK: - Currency Formatter

/// Thread-safe currency formatter cache using os_unfair_lock for minimal overhead
private enum CurrencyFormatters {
    private static var formatters: [String: NumberFormatter] = [:]
    private static var lock = os_unfair_lock()

    static func formatter(for currencyCode: String) -> NumberFormatter {
        let key = currencyCode.uppercased()

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if let cached = formatters[key] {
            return cached
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = key

        switch key {
        case "USD":
            formatter.currencySymbol = "$"
        case "EUR":
            formatter.currencySymbol = "€"
        case "GBP":
            formatter.currencySymbol = "£"
        case "JPY":
            formatter.currencySymbol = "¥"
            formatter.maximumFractionDigits = 0
        case "CNY":
            formatter.currencySymbol = "¥"
        case "CAD":
            formatter.currencySymbol = "CA$"
        case "AUD":
            formatter.currencySymbol = "A$"
        default:
            formatter.currencySymbol = key
        }

        formatters[key] = formatter
        return formatter
    }

    static func format(cents: Int, currency: String) -> String {
        let amount = Double(cents) / 100.0
        let formatter = self.formatter(for: currency)
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }
}

// MARK: - API Response Models

/// Raw usage period data from API
struct UsagePeriodResponse: Codable {
    let utilization: Int
    let resetsAt: String?

    /// Memberwise initializer (also used by tests)
    init(utilization: Int, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Dynamic usage response - parses any fields from the API
struct UsageResponse {
    let items: [String: UsagePeriodResponse]

    /// Memberwise initializer (also used by tests)
    init(items: [String: UsagePeriodResponse]) {
        self.items = items
    }

    /// Ordered keys based on priority:
    /// 1. five_hour
    /// 2. seven_day
    /// 3. seven_day_* variants
    /// 4. others (alphabetically)
    var orderedKeys: [String] {
        var priorityKeys: [String] = []
        var sevenDayKeys: [String] = []
        var otherKeys: [String] = []

        for key in items.keys {
            if key == "five_hour" {
                priorityKeys.insert(key, at: 0)
            } else if key == "seven_day" {
                priorityKeys.append(key)
            } else if key.hasPrefix("seven_day_") {
                sevenDayKeys.append(key)
            } else {
                otherKeys.append(key)
            }
        }

        sevenDayKeys.sort()
        otherKeys.sort()

        return priorityKeys + sevenDayKeys + otherKeys
    }
}

extension UsageResponse: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var parsedItems: [String: UsagePeriodResponse] = [:]

        for key in container.allKeys {
            // Try to decode as UsagePeriodResponse, skip if null or invalid
            if let period = try? container.decodeIfPresent(UsagePeriodResponse.self, forKey: key) {
                parsedItems[key.stringValue] = period
            }
        }

        self.items = parsedItems
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

// MARK: - Processed Usage Models

/// A single usage item with display properties
struct UsageItem: Identifiable {
    let id: String
    let key: String
    let utilization: Int
    let resetsAt: Date?
    let parseError: String?

    init(key: String, utilization: Int, resetsAt: Date?, parseError: String? = nil) {
        self.id = key
        self.key = key
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.parseError = parseError
    }

    /// Display title for the usage item
    /// - "five_hour" → "5-Hour Usage"
    /// - "seven_day" → "7-Day Usage"
    /// - "seven_day_opus" → "7-Day Opus"
    /// - "seven_day_oauth_apps" → "7-Day Oauth Apps"
    /// - others → capitalize and replace underscores
    var displayTitle: String {
        switch key {
        case "five_hour":
            return "5-Hour Usage"
        case "seven_day":
            return "7-Day Usage"
        default:
            if key.hasPrefix("seven_day_") {
                let suffix = String(key.dropFirst(10))
                let formatted = suffix.split(separator: "_")
                    .map { $0.capitalized }
                    .joined(separator: " ")
                return "7-Day \(formatted)"
            }
            // Generic: replace underscores, capitalize
            return key.split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    var percentage: Double {
        Double(utilization) / 100.0
    }

    var displayText: String {
        "\(utilization)%"
    }

    var isNearLimit: Bool {
        utilization >= 80
    }

    var isAtLimit: Bool {
        utilization >= 100
    }

    /// Usage status level for color coding
    var statusLevel: UsageStatusLevel {
        if isAtLimit { return .critical }
        if isNearLimit { return .warning }
        return .normal
    }

    /// Short title for compact display
    var compactTitle: String {
        switch key {
        case "five_hour":
            return "5-Hour"
        case "seven_day":
            return "7-Day"
        default:
            if key.hasPrefix("seven_day_") {
                let suffix = String(key.dropFirst(10))
                return suffix.capitalized
            }
            return displayTitle
        }
    }

    /// Whether to use long reset display (for non-5-hour items)
    var useLongResetDisplay: Bool {
        key != "five_hour"
    }

    // MARK: - Reset Time Display Properties

    private var resetTimeResult: ResetTimeFormatter.Result {
        ResetTimeFormatter.parse(resetsAt)
    }

    /// Reset time display for short intervals (5-hour style)
    /// e.g., "14:30 · in 2h 30m"
    var resetTimeDisplay: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.shortDisplay(for: tc)
        }
    }

    /// Short reset time for menubar display (e.g., "14:30")
    var resetTimeShort: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.timeOnly(for: tc)
        }
    }

    /// Compact remaining time in English (e.g., "2h 30m", "3d 5h", "Ready")
    var resetTimeRemaining: String? {
        switch resetTimeResult {
        case .none: return ResetTimeFormatter.readyText
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.compactRemaining(for: tc)
        }
    }

    /// Static reset target for at-limit display (e.g., "until 14:30", "until Tmr 14:30")
    /// Unlike `resetTimeRemaining`, this value doesn't change over time.
    var resetTimeTarget: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return "until \(ResetTimeFormatter.formatResetTime(tc.date))"
        }
    }

    /// Reset time display for longer intervals (7-day style)
    /// e.g., "Jan 5 · in 3d 5h" or "14:30 · in 2h 30m" (if today)
    var resetTimeDisplayLong: String? {
        switch resetTimeResult {
        case .none: return nil
        case .expired: return ResetTimeFormatter.updatingText
        case .valid(let tc): return ResetTimeFormatter.longDisplay(for: tc)
        }
    }

}

// MARK: - Reset Time Formatting

/// Handles all reset time formatting logic for UsageItem
private enum ResetTimeFormatter {
    static let updatingText = "Updating..."
    static let readyText = "Ready"

    struct TimeComponents {
        let date: Date
        let days: Int
        let hours: Int
        let minutes: Int

        var totalSeconds: Int {
            days * Constants.Time.secondsPerDay
                + hours * Constants.Time.secondsPerHour
                + minutes * Constants.Time.secondsPerMinute
        }

        /// Formatted remaining time (e.g., "2h 30m")
        var remainingFormatted: String? {
            let interval = TimeInterval(max(60, totalSeconds))
            return DateFormatters.remainingTime.string(from: interval)
        }

        /// Formatted remaining time with "in" prefix (e.g., "in 2h 30m")
        var remainingWithPrefix: String {
            if let formatted = remainingFormatted {
                return "in \(formatted)"
            }
            // Fallback (should not happen)
            return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
        }
    }

    enum Result {
        case none
        case expired
        case valid(TimeComponents)
    }

    /// Parse resetsAt date into TimeComponents
    static func parse(_ resetsAt: Date?) -> Result {
        guard let resetsAt = resetsAt else { return .none }
        let interval = resetsAt.timeIntervalSince(Date())
        guard interval > 0 else { return .expired }

        let totalSeconds = Int(interval)
        return .valid(TimeComponents(
            date: resetsAt,
            days: totalSeconds / Constants.Time.secondsPerDay,
            hours: (totalSeconds % Constants.Time.secondsPerDay) / Constants.Time.secondsPerHour,
            minutes: (totalSeconds % Constants.Time.secondsPerHour) / Constants.Time.secondsPerMinute
        ))
    }

    /// Round date to nearest minute
    static func roundToNearestMinute(_ date: Date) -> Date {
        let seconds = Calendar.current.component(.second, from: date)
        let adjustment = seconds >= 30 ? (60 - seconds) : -seconds
        return date.addingTimeInterval(TimeInterval(adjustment))
    }

    /// Format reset time with relative prefix (e.g., "14:30", "Tmr 14:30", "2/1 14:30")
    static func formatResetTime(_ date: Date) -> String {
        let rounded = roundToNearestMinute(date)
        let calendar = Calendar.current
        if calendar.isDateInToday(rounded) {
            return DateFormatters.timeOnly.string(from: rounded)
        } else if calendar.isDateInTomorrow(rounded) {
            return "Tmr \(DateFormatters.timeOnly.string(from: rounded))"
        } else {
            return DateFormatters.dateTime.string(from: rounded)
        }
    }

    /// Short display: "14:30 · in 2h 30m"
    static func shortDisplay(for tc: TimeComponents) -> String {
        let timeStr = formatResetTime(tc.date)
        return "\(timeStr) · \(tc.remainingWithPrefix)"
    }

    /// Long display: "Jan 5 · in 3d 5h" or "14:30 · in 2h 30m" (if today)
    static func longDisplay(for tc: TimeComponents) -> String {
        let rounded = roundToNearestMinute(tc.date)
        guard let remaining = tc.remainingFormatted else {
            // Fallback: just show the date/time without remaining
            return Calendar.current.isDateInToday(rounded)
                ? DateFormatters.timeOnly.string(from: rounded)
                : DateFormatters.monthDay.string(from: rounded)
        }

        if Calendar.current.isDateInToday(rounded) {
            let timeStr = DateFormatters.timeOnly.string(from: rounded)
            return "\(timeStr) · in \(remaining)"
        } else {
            let dateStr = DateFormatters.monthDay.string(from: rounded)
            return "\(dateStr) · in \(remaining)"
        }
    }

    /// Compact remaining only: "2h 30m"
    static func compactRemaining(for tc: TimeComponents) -> String? {
        tc.remainingFormatted
    }

    /// Time only: "14:30"
    static func timeOnly(for tc: TimeComponents) -> String {
        DateFormatters.timeOnly.string(from: roundToNearestMinute(tc.date))
    }
}

/// Usage status levels for UI color coding
enum UsageStatusLevel {
    case normal    // < 80%
    case warning   // 80-99%
    case critical  // >= 100%

    /// Create status level from percentage value
    static func from(percentage: Int) -> UsageStatusLevel {
        if percentage >= 100 { return .critical }
        if percentage >= 80 { return .warning }
        return .normal
    }
}

/// Processed usage summary with ordered items
struct UsageSummary {
    let items: [UsageItem]
    let lastUpdated: Date

    /// Primary usage item (five_hour if available, otherwise first item)
    var primaryItem: UsageItem? {
        items.first { $0.key == "five_hour" } ?? items.first
    }

    /// Whether primary item is at limit (for auto-refresh pause)
    var isPrimaryAtLimit: Bool {
        primaryItem?.isAtLimit ?? false
    }

    /// Primary item's reset time (for scheduling resume)
    var primaryResetsAt: Date? {
        primaryItem?.resetsAt
    }
}

// MARK: - Extra Usage Models

struct PrepaidCredits: Codable {
    let amount: Int
    let currency: String
    let autoReloadSettings: AutoReloadSettings?

    enum CodingKeys: String, CodingKey {
        case amount, currency
        case autoReloadSettings = "auto_reload_settings"
    }
}

struct AutoReloadSettings: Codable {
    let enabled: Bool?
}

struct OverageSpendLimit: Codable {
    let organizationUuid: String
    let isEnabled: Bool
    let monthlyCreditLimit: Int
    let currency: String
    let usedCredits: Int
    let outOfCredits: Bool
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case organizationUuid = "organization_uuid"
        case isEnabled = "is_enabled"
        case monthlyCreditLimit = "monthly_credit_limit"
        case currency
        case usedCredits = "used_credits"
        case outOfCredits = "out_of_credits"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var usedPercentage: Int {
        guard monthlyCreditLimit > 0 else { return 0 }
        return Int(Double(usedCredits) / Double(monthlyCreditLimit) * 100)
    }

    var formattedUsedCredits: String {
        CurrencyFormatters.format(cents: usedCredits, currency: currency)
    }

    var formattedMonthlyLimit: String {
        CurrencyFormatters.format(cents: monthlyCreditLimit, currency: currency)
    }

    var resetDateDisplay: String {
        let calendar = Calendar.current
        let now = Date()
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: now),
              let firstOfNextMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth)) else {
            return ""
        }
        return "Resets \(DateFormatters.monthDay.string(from: firstOfNextMonth))"
    }
}

struct ExtraUsageSummary {
    let credits: PrepaidCredits?
    let spendLimit: OverageSpendLimit?

    var formattedBalance: String? {
        guard let credits = credits else { return nil }
        return CurrencyFormatters.format(cents: credits.amount, currency: credits.currency)
    }

    var isAutoReloadOn: Bool {
        credits?.autoReloadSettings?.enabled ?? false
    }
}

// MARK: - Billing Request/Response Models

struct SetupOverageBillingRequest: Codable {
    let seatTierMonthlySpendLimits: SeatTierLimits
    let orgMonthlySpendLimit: Int

    enum CodingKeys: String, CodingKey {
        case seatTierMonthlySpendLimits = "seat_tier_monthly_spend_limits"
        case orgMonthlySpendLimit = "org_monthly_spend_limit"
    }
}

struct SeatTierLimits: Codable {
    let teamStandard: Int?
    let teamTier1: Int?

    enum CodingKeys: String, CodingKey {
        case teamStandard = "team_standard"
        case teamTier1 = "team_tier_1"
    }
}

struct SetupOverageBillingResponse: Codable {
    let customerWasCreated: Bool
    let contractWasCreated: Bool

    enum CodingKeys: String, CodingKey {
        case customerWasCreated = "customer_was_created"
        case contractWasCreated = "contract_was_created"
    }
}
