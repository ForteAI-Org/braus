import CLIProviders
import Foundation
import Security
import Testing

@Suite("System Keychain adapter", .enabled(if: ProcessInfo.processInfo.environment["BRAUS_LIVE_KEYCHAIN"] == "1"))
struct SystemKeychainLiveTests {
    @Test
    func readsOnlyTheTemporaryTestService() throws {
        let service = "dev.forte.braus.test.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "test"]
        var item = query
        item[kSecValueData as String] = Data("FAKE-TEMPORARY-PASSWORD".utf8)
        try #require(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        var needsCleanup = true
        defer { if needsCleanup { #expect(SecItemDelete(query as CFDictionary) == errSecSuccess) } }
        #expect(try SystemKeychain().password(service: service) == "FAKE-TEMPORARY-PASSWORD")
        try #require(SecItemDelete(query as CFDictionary) == errSecSuccess)
        needsCleanup = false
        #expect(throws: ProviderKeychainKey.Failure.notFound(service: service)) {
            try SystemKeychain().password(service: service)
        }
    }
}
