import Foundation

// MARK: - Bootstrap API Response Models

struct BootstrapResponse: Codable {
    let account: BootstrapAccount?
}

struct BootstrapAccount: Codable {
    let uuid: String
    let memberships: [BootstrapMembership]?
}

struct BootstrapMembership: Codable {
    let organization: BootstrapOrganization
}

struct BootstrapOrganization: Codable {
    let uuid: String
    let capabilities: [String]?

    var subscriptionType: SubscriptionType {
        SubscriptionType.from(capabilities: capabilities)
    }
}

// MARK: - Bootstrap Data Extraction

extension BootstrapResponse {
    var primaryOrganization: BootstrapOrganization? {
        account?.memberships?.first?.organization
    }

    var subscriptionType: SubscriptionType {
        primaryOrganization?.subscriptionType ?? SubscriptionType(rawValue: nil)
    }

    var organizationId: String? {
        primaryOrganization?.uuid
    }

    var hasValidAccount: Bool {
        account != nil && primaryOrganization != nil
    }
}
