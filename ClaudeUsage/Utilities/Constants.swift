import Foundation
import SwiftUI

enum Constants {
    enum App {
        static let bundleIdentifier = "com.claudeusage.app"
    }

    enum API {
        static let baseURL = URL(string: "https://claude.ai/api")!
        static let loginURL = URL(string: "https://claude.ai/login")!
        static let origin = "https://claude.ai"
        static let referer = "https://claude.ai/"
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        static let requestTimeout: TimeInterval = 30
    }

    enum Keychain {
        static let serviceName = "com.claudeusage.app"
        static let accountName = "session-credentials"
    }

    enum Refresh {
        static let intervalSeconds: TimeInterval = 5 * 60 // 5 minutes
        static let retryDelaySeconds: TimeInterval = 30
        /// Additional delay after reset time before refreshing (seconds)
        static let resumeDelaySeconds: TimeInterval = 5
    }

    enum Login {
        /// Delay to wait for cookies to sync after login detection
        static let cookieSyncDelay: TimeInterval = 2.0
    }

    enum UI {
        static let menuBarWidth: CGFloat = 300
        static let loginWindowWidth: CGFloat = 480
        static let loginWindowHeight: CGFloat = 640
        static let loginWindowTitle = "Log in to Claude"

        // Status bar dimensions
        static let statusBarMinWidth: CGFloat = 45
        static let statusBarHeight: CGFloat = 22
        static let statusBarPadding: CGFloat = 4

        // Card styling
        static let cardCornerRadius: CGFloat = 6
        static let cardHorizontalPadding: CGFloat = 12
        static let cardVerticalPadding: CGFloat = 10

        // Compact layout threshold
        static let compactLayoutThreshold = 4
    }

    enum Colors {
        /// Claude brand orange color (RGB: 217, 115, 64)
        static let claudeOrange = (red: 0.85, green: 0.45, blue: 0.25)

        /// Card background color - adapts to light/dark mode
        static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor.white.withAlphaComponent(0.05)
            } else {
                return NSColor.white.withAlphaComponent(0.85)
            }
        })
    }

    /// Commonly used font sizes
    enum Fonts {
        static let title: CGFloat = 14
        static let body: CGFloat = 12
        static let caption: CGFloat = 11
        static let footnote: CGFloat = 10
        static let micro: CGFloat = 9
        static let statusBarPrimary: CGFloat = 9
        static let statusBarSecondary: CGFloat = 8
        static let usagePercentage: CGFloat = 22
        static let extraUsageAmount: CGFloat = 20
    }

    enum Time {
        static let secondsPerMinute = 60
        static let secondsPerHour = 3600
        static let secondsPerDay = 86400
    }

    enum Domain {
        /// Valid domains for Claude authentication cookies
        private static let validDomains: Set<String> = ["claude.ai", "anthropic.com"]

        /// Validates that a cookie domain belongs to Claude/Anthropic
        /// Accepts: "claude.ai", ".claude.ai", "*.claude.ai", "anthropic.com", ".anthropic.com", "*.anthropic.com"
        /// Rejects: "not-claude.ai", "claude.ai.evil.com"
        static func isValidCookieDomain(_ domain: String) -> Bool {
            let lowercased = domain.lowercased()
            let normalized = lowercased.hasPrefix(".") ? String(lowercased.dropFirst()) : lowercased

            return validDomains.contains { validDomain in
                normalized == validDomain || normalized.hasSuffix(".\(validDomain)")
            }
        }
    }
}
