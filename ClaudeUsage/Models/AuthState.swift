import Foundation

enum AuthState: Equatable {
    case unknown
    case notAuthenticated
    case authenticated(subscriptionType: SubscriptionType)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var subscriptionType: SubscriptionType? {
        if case .authenticated(let type) = self { return type }
        return nil
    }

    /// Display name for the subscription type (e.g., "Pro", "Max")
    var tierDisplayName: String? {
        subscriptionType?.displayName
    }
}
