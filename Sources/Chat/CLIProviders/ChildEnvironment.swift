import ChatCore
import ModelTransports

/// ChildEnvironment builds the provider child's whole environment with the same filter as the app,
/// admitting at most one credential selected by the composition layer.
nonisolated public enum ChildEnvironment {
    public enum Credential: Sendable, Equatable {
        case none
        case keychain(ProviderKeychainKey)
        case namedVariable(String)
    }

    /// Filters inherited values, then adds only the selected credential. A missing named variable adds nothing.
    /// A Keychain failure prevents the child from starting; the password is read once and retained only in the result.
    public static func build(
        inherited : [String: String],
        provider  : ChatProvider,
        credential: Credential,
        keychain  : any KeychainReading
    ) throws(ProviderKeychainKey.Failure) -> [String: String] {
        var result = CodexCLIClient.environment(from: inherited)
        switch credential {
        case .none: break
        case .namedVariable(let name): result[name] = inherited[name]
        case .keychain(let key):
            let password = try keychain.password(service: key.service)
            guard !password.isEmpty else { throw .empty(service: key.service) }
            result[ProviderKeychainKey.variable(for: provider)] = password
        }
        return result
    }
}
