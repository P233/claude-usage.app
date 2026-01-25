import Foundation

enum AuthState: Equatable {
    case unknown
    case notAuthenticated
    case authenticating
    case authenticated(organizationId: String, subscriptionType: SubscriptionType)
    case error(String)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var organizationId: String? {
        if case .authenticated(let orgId, _) = self { return orgId }
        return nil
    }

    var subscriptionType: SubscriptionType? {
        if case .authenticated(_, let type) = self { return type }
        return nil
    }

    /// Display name for the subscription type (e.g., "Pro", "Max")
    var tierDisplayName: String? {
        subscriptionType?.displayName
    }
}

struct StoredCredentials: Codable {
    let cookies: [CookieData]
    let organizationId: String
    let subscriptionType: SubscriptionType
    let savedAt: Date

    // MARK: - Migration Support

    /// Legacy field for backwards compatibility during migration
    private let rateLimitTier: String?

    init(cookies: [CookieData], organizationId: String, subscriptionType: SubscriptionType, savedAt: Date) {
        self.cookies = cookies
        self.organizationId = organizationId
        self.subscriptionType = subscriptionType
        self.savedAt = savedAt
        self.rateLimitTier = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cookies = try container.decode([CookieData].self, forKey: .cookies)
        organizationId = try container.decode(String.self, forKey: .organizationId)
        savedAt = try container.decode(Date.self, forKey: .savedAt)

        // Try to decode subscriptionType first, fallback to rateLimitTier for migration
        if let type = try? container.decode(SubscriptionType.self, forKey: .subscriptionType) {
            subscriptionType = type
            rateLimitTier = nil
        } else {
            // Migration path: use rateLimitTier to infer subscriptionType
            rateLimitTier = try? container.decode(String.self, forKey: .rateLimitTier)
            subscriptionType = SubscriptionType.from(rateLimitTier: rateLimitTier)
        }
    }

    enum CodingKeys: String, CodingKey {
        case cookies
        case organizationId
        case subscriptionType
        case rateLimitTier  // Legacy key for migration
        case savedAt
    }

    struct CookieData: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool

        init(from cookie: HTTPCookie) {
            self.name = cookie.name
            self.value = cookie.value
            self.domain = cookie.domain
            self.path = cookie.path
            self.expiresDate = cookie.expiresDate
            self.isSecure = cookie.isSecure
            self.isHTTPOnly = cookie.isHTTPOnly
        }

        func toHTTPCookie() -> HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path,
                .secure: isSecure ? "TRUE" : "FALSE"
            ]

            if let expiresDate = expiresDate {
                properties[.expires] = expiresDate
            }

            // HTTPOnly flag uses an undocumented key
            // This ensures the cookie maintains its HTTPOnly status when reconstructed
            if isHTTPOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }

            return HTTPCookie(properties: properties)
        }
    }
}
