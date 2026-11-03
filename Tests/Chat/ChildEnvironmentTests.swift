import ChatCore
import CLIProviders
import Foundation
import ModelTransports
import Security
import Synchronization
import Testing

@Suite("Child environment credentials")
struct ChildEnvironmentTests {
    nonisolated final class Keychain: KeychainReading {
        let result: Result<String, ProviderKeychainKey.Failure>
        let services = Mutex<[String]>([])

        init(_ result: Result<String, ProviderKeychainKey.Failure>) { self.result = result }

        func password(service: String) throws(ProviderKeychainKey.Failure) -> String {
            services.withLock { $0.append(service) }
            return try result.get()
        }
    }

    private let inherited = ["HOME": "/fake/home", "USER": "test", "PATH": "/usr/bin:/bin",
                             "TMPDIR": "/fake/tmp", "CODEX_HOME": "/fake/login", "LC_ALL": "en_US.UTF-8",
                             "HTTPS_PROXY": "https://proxy.invalid", "SSL_CERT_FILE": "/fake/cert",
                             "ANTHROPIC_API_KEY": "FAKE-INHERITED", "OPENAI_API_KEY": "FAKE-INHERITED",
                             "ANTHROPIC_AUTH_TOKEN": "FAKE-INHERITED", "ANTHROPIC_BASE_URL": "https://invalid",
                             "CLAUDE_CODE_OAUTH_TOKEN": "FAKE-INHERITED", "X": "FAKE-NAMED"]

    @Test(arguments: [ChatProvider.claude, .codex])
    func defaultUsesTheSharedFilterWithoutReadingKeychain(_ provider: ChatProvider) throws {
        let keychain = Keychain(.failure(.notFound(service: "unused")))
        let result = try ChildEnvironment.build(
            inherited: inherited, provider: provider, credential: .none, keychain: keychain
        )
        #expect(result == CodexCLIClient.environment(from: inherited))
        #expect(keychain.services.withLock { $0.isEmpty })
    }

    @Test(arguments: [ChatProvider.claude, .codex])
    func readsExactlyOneServiceForOnlyTheSelectedProvider(_ provider: ChatProvider) throws {
        let keychain = Keychain(.success("FAKE-KEYCHAIN"))
        let result = try ChildEnvironment.build(
            inherited: inherited, provider: provider,
            credential: .keychain(ProviderKeychainKey(service: "test.service")), keychain: keychain
        )
        let variable = provider == .claude ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"
        var expected = CodexCLIClient.environment(from: inherited)
        expected[variable] = "FAKE-KEYCHAIN"
        #expect(result == expected)
        #expect(ProviderKeychainKey.variable(for: provider) == variable)
        #expect(keychain.services.withLock { $0 } == ["test.service"])
    }

    @Test(arguments: ["X", "ABSENT"])
    func onlyTheNamedVariableIsAdmitted(_ name: String) throws {
        let keychain = Keychain(.failure(.notFound(service: "unused")))
        var expected = CodexCLIClient.environment(from: inherited)
        expected[name] = inherited[name]
        let result = try ChildEnvironment.build(
            inherited: inherited, provider: .claude, credential: .namedVariable(name), keychain: keychain
        )
        #expect(result == expected)
        #expect(keychain.services.withLock { $0.isEmpty })
    }

    @Test(arguments: [ProviderKeychainKey.Failure.notFound(service: "test.service"),
                      .empty(service: "test.service"), .unreadable(service: "test.service", status: -50),
                      .unreadable(service: "test.service", status: errSecInteractionNotAllowed)])
    func failuresStayTypedAndNeverContainCredentialValues(_ failure: ProviderKeychainKey.Failure) {
        let keychain = Keychain(.failure(failure))
        #expect(throws: failure) {
            try ChildEnvironment.build(
                inherited: inherited, provider: .claude,
                credential: .keychain(ProviderKeychainKey(service: "test.service")), keychain: keychain
            )
        }
        #expect(failure.localizedDescription.contains("test.service"))
        for value in ["FAKE-INHERITED", "FAKE-KEYCHAIN", "FAKE-NAMED"] {
            #expect(!failure.localizedDescription.contains(value))
            #expect(!String(describing: failure).contains(value))
        }
    }

    @Test(arguments: [ChatProvider.claude, .codex])
    func providerConfigurationValuesArePreserved(_ provider: ChatProvider) throws {
        let configuration = ["CLAUDE_CONFIG_DIR": "/fake/custom config", "NODE_EXTRA_CA_CERTS": "/fake/custom cert.pem"]
        let result = try ChildEnvironment.build(
            inherited: inherited.merging(configuration) { _, new in new },
            provider: provider,
            credential: .none,
            keychain: Keychain(.failure(.notFound(service: "unused")))
        )
        for (name, value) in configuration {
            #expect(result[name] == (provider == .claude ? value : nil))
        }
    }

    @Test
    func anEmptyNamedVariableCannotLaunchAChild() {
        let failure = ProviderKeychainKey.Failure.emptyVariable(name: "X")
        let keychain = Keychain(.success("FAKE-KEYCHAIN"))
        #expect(throws: failure) {
            try ChildEnvironment.build(
                inherited: inherited.merging(["X": ""]) { _, new in new },
                provider: .claude,
                credential: .namedVariable("X"),
                keychain: keychain
            )
        }
        #expect(keychain.services.withLock { $0.isEmpty })
        #expect(failure.localizedDescription == "The environment variable 'X' selected by --pass-env is empty.")
    }

    @Test
    func anEmptyPasswordCannotLaunchAChild() {
        #expect(throws: ProviderKeychainKey.Failure.empty(service: "test.service")) {
            try ChildEnvironment.build(
                inherited: inherited, provider: .codex,
                credential: .keychain(ProviderKeychainKey(service: "test.service")), keychain: Keychain(.success(""))
            )
        }
    }
}
