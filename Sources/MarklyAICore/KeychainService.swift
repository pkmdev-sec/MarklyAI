import Foundation
import Security

/// Service for securely storing and retrieving the Anthropic API key.
/// Tries macOS Keychain first, falls back to UserDefaults if Keychain is unavailable
/// (e.g., ad-hoc signed builds without Keychain entitlements).
enum KeychainService {
    private static let service = "com.marklyai.app"
    private static let apiKeyAccount = "anthropic-api-key"
    private static let userDefaultsKey = "marklyai_ak"

    /// Save the API key — tries Keychain, falls back to UserDefaults
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        // Try Keychain first
        deleteFromKeychain()

        guard let data = key.data(using: .utf8) else { return false }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: apiKeyAccount,
            kSecValueData: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            // Also save to UserDefaults as backup
            UserDefaults.standard.set(key, forKey: userDefaultsKey)
            return true
        }

        // Keychain failed — save to UserDefaults only
        UserDefaults.standard.set(key, forKey: userDefaultsKey)
        return true
    }

    /// Retrieve the API key — tries Keychain first, then UserDefaults
    static func getAPIKey() -> String? {
        // Try Keychain first
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: apiKeyAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        // Fallback to UserDefaults
        return UserDefaults.standard.string(forKey: userDefaultsKey)
    }

    /// Delete the API key from all storage
    @discardableResult
    static func deleteAPIKey() -> Bool {
        deleteFromKeychain()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        return true
    }

    private static func deleteFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: apiKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
