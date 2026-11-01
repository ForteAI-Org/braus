import Foundation
import Security

/// SystemKeychain reads one generic password through Security. A missing, empty or undecodable item fails
/// before a provider child starts; errors contain only the service and system status.
nonisolated public struct SystemKeychain: KeychainReading {
    public init() {}

    public func password(service: String) throws(ProviderKeychainKey.Failure) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw .notFound(service: service) }
        guard status == errSecSuccess else { throw .unreadable(service: service, status: status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw .unreadable(service: service, status: errSecDecode)
        }
        guard !password.isEmpty else { throw .empty(service: service) }
        return password
    }
}
