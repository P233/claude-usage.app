import Foundation
import Security
import os.log

private let logger = Logger(subsystem: Constants.App.bundleIdentifier, category: "KeychainService")

protocol KeychainServiceProtocol {
    func save(credentials: StoredCredentials) throws
    func loadCredentials() throws -> StoredCredentials?
    func deleteCredentials() throws
}

final class KeychainService: KeychainServiceProtocol {

    enum KeychainError: Error, LocalizedError {
        case encodingFailed
        case decodingFailed
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case itemNotFound

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Failed to encode credentials"
            case .decodingFailed:
                return "Failed to decode credentials"
            case .saveFailed:
                return "Failed to save to Keychain"
            case .loadFailed:
                return "Failed to load from Keychain"
            case .deleteFailed:
                return "Failed to delete from Keychain"
            case .itemNotFound:
                return "Credentials not found in Keychain"
            }
        }
    }

    private let serviceName: String
    private let accountName: String

    init(
        serviceName: String = Constants.Keychain.serviceName,
        accountName: String = Constants.Keychain.accountName
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
    }

    func save(credentials: StoredCredentials) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(credentials) else {
            logger.error("Failed to encode credentials")
            throw KeychainError.encodingFailed
        }

        // Delete existing item first
        try? deleteCredentials()

        // Use kSecAttrAccessibleWhenUnlockedThisDeviceOnly for enhanced security:
        // - Only accessible when device is unlocked
        // - Not transferred to new devices (stays on this device only)
        // - More secure than kSecAttrAccessibleAfterFirstUnlock
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Failed to save to Keychain: \(status)")
            throw KeychainError.saveFailed(status)
        }

        logger.info("Credentials saved to Keychain")
    }

    func loadCredentials() throws -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            logger.debug("No credentials found in Keychain")
            return nil
        }

        guard status == errSecSuccess,
              let data = result as? Data else {
            logger.error("Failed to load from Keychain: \(status)")
            throw KeychainError.loadFailed(status)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let credentials = try? decoder.decode(StoredCredentials.self, from: data) else {
            logger.error("Failed to decode credentials from Keychain data")
            throw KeychainError.decodingFailed
        }

        logger.info("Credentials loaded from Keychain")
        return credentials
    }

    func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete from Keychain: \(status)")
            throw KeychainError.deleteFailed(status)
        }

        logger.info("Credentials deleted from Keychain")
    }
}
