import Foundation
import Security

/// 钥匙串存取:仅用于保存邮箱授权码这类敏感凭据。
/// 无签名/无 entitlement 环境(如部分模拟器构建)下 SecItem 会失败,降级到 UserDefaults。
enum Keychain {
    private static func fallbackKey(service: String, account: String) -> String {
        "kc.fallback.\(service).\(account)"
    }

    @discardableResult
    static func set(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
                return true
            }
        } else if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
                return true
            }
        }
        // 降级:钥匙串不可用时存 UserDefaults(仅个人本地 App 场景)
        UserDefaults.standard.set(value, forKey: fallbackKey(service: service, account: account))
        return false
    }

    static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: fallbackKey(service: service, account: account))
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(service: service, account: account))
    }
}
