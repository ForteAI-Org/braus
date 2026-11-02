import ChatCore
import Foundation

/// ProviderKeychainKey names one provider credential by Keychain service. Only the child environment builder
/// receives its value; the credential is never persisted or included in diagnostics.
nonisolated public struct ProviderKeychainKey: Sendable, Equatable {
    public let service: String

    public init(service: String) { self.service = service }

    /// Returns the environment variable read by the provider's command line.
    public static func variable(for provider: ChatProvider) -> String {
        switch provider {
        case .claude: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        }
    }

    /// Failure identifies the service, variable name or system status, never the credential value.
    public enum Failure: Error, Equatable, LocalizedError, CustomStringConvertible {
        case notFound(service: String)
        case unreadable(service: String, status: Int32)
        case empty(service: String)
        case emptyVariable(name: String)

        public var description: String {
            switch self {
            case .notFound(let service): "No provider credential found for Keychain service '\(service)'."
            case .unreadable(let service, let status):
                "Could not read provider credential for Keychain service '\(service)' (status \(status))."
            case .emptyVariable(let name): "The environment variable '\(name)' selected by --pass-env is empty."
            case .empty(let service): "The provider credential for Keychain service '\(service)' is empty."
            }
        }

        public var errorDescription: String? { description }
    }
}

/// KeychainReading reads one generic password by service without exposing its value through diagnostics.
nonisolated public protocol KeychainReading: Sendable {
    func password(service: String) throws(ProviderKeychainKey.Failure) -> String
}
