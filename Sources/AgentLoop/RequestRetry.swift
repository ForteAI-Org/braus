import Foundation
import ModelTransports

/// RequestRetry admits at most two retries of a model request before any tool ran.
/// Human control suspends retryable work so a later review turn can request it again.
nonisolated public struct RequestRetry: Sendable, Equatable {
    public static let maximumAttempts = 3

    public enum Failure: Sendable, Equatable {
        case retryable(status: Int?)
        case notRetryable
    }

    public enum Decision: Sendable, Equatable {
        case retry(after: Duration)
        case suspend
        case fail
    }

    public static func classify(_ error: any Error) -> Failure {
        if case ProviderError.http(let status, _) = error,
           status == 429 || (500...599).contains(status) {
            return .retryable(status: status)
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
                return .retryable(status: nil)
            default: break
            }
        }
        return .notRetryable
    }

    public static func decide(
        _ failure: Failure,
        attempt: Int,
        anyToolRan: Bool,
        isSuspended: Bool
    ) -> Decision {
        guard case .retryable = failure, !anyToolRan else { return .fail }
        if isSuspended { return .suspend }
        guard attempt > 0, attempt < maximumAttempts else { return .fail }
        return .retry(after: .seconds(attempt == 1 ? 1 : 3))
    }
}
