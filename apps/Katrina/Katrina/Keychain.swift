import Foundation
import Security

/// Secrets live in the Keychain only: the Anthropic key, the GitHub token and the Mac pairing code.
enum Keychain {
    private static let service = "ca.pmphealthcare.katrina"

    static var apiKey: String? {
        get { read("anthropic-api-key") }
        set { write("anthropic-api-key", newValue) }
    }
    static var githubToken: String? {
        get { read("github-token") }
        set { write("github-token", newValue) }
    }
    /// 16 characters, no dashes, upper case. Signs every order sent to the Macs.
    static var pairingCode: String? {
        get { read("crew-pairing-code") }
        set { write("crew-pairing-code", newValue) }
    }

    private static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
