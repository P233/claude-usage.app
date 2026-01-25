import Foundation

struct UpdateOverageSpendLimitRequest: Codable {
    let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }
}
