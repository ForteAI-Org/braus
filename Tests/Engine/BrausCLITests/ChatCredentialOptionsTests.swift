import CLIProviders
import Testing
@testable import braus

@Suite("Chat credential options")
struct ChatCredentialOptionsTests {
    @Test
    func credentialsAreOptInAndKeepTheirNames() throws {
        #expect(try ChatOptions(arguments: []).credential == .none)
        #expect(try ChatOptions(arguments: ["--provider-key-service", "test.service"]).credential
                == .keychain(ProviderKeychainKey(service: "test.service")))
        #expect(try ChatOptions(arguments: ["--pass-env", "EXPLICIT_CREDENTIAL"]).credential
                == .namedVariable("EXPLICIT_CREDENTIAL"))
        #expect(ChatOptions.usage.contains("--provider-key-service <service>"))
        #expect(ChatOptions.usage.contains("--pass-env <NAME>"))
    }

    @Test(arguments: [
        ["--provider-key-service"], ["--pass-env"], ["--pass-env", ""],
        ["--provider-key-service", "one", "--pass-env", "X"],
        ["--pass-env", "X", "--provider-key-service", "one"],
        ["--pass-env", "X", "--pass-env", "Y"],
        ["--provider-key-service", "one", "--provider-key-service", "two"]
    ])
    func invalidCredentialsCannotLaunchAProvider(_ arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try ChatOptions(arguments: arguments) }
    }
}
