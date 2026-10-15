//
//  ProviderFailure.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import Foundation

/// ProviderFailure is a turn that the provider, not the agent, ended badly, with its kind read only from what the
/// provider states in fields (an HTTP status of its API, a result subtype, a rejected rate limit, the command line's
/// exit status, a stream with no result), never from its text. A run of many tasks reads `kind` and `retryable` to
/// tell "the provider or the Mac, stop" from a task that failed, without parsing the message.
public struct ProviderFailure: Error, LocalizedError, Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The account's rate limit refused the turn (a rejected `rate_limit_event`, or HTTP 429).
        case rateLimited = "rate_limited"
        /// The provider refused the credentials (HTTP 401 or 403).
        case auth
        /// The provider's service failed or was overloaded (HTTP 5xx, 529).
        case unavailable
        /// The API refused the request for another stated reason (another HTTP status).
        case apiError = "api_error"
        /// The turn ended in error with no HTTP status: a result subtype such as a turn limit, or a failure the
        /// provider stated only in words (a lost connection among them).
        case turnError = "turn_error"
        /// The command line exited without a result and without an error: the output was cut.
        case noResult = "no_result"
        /// The command line exited with a failing status and stated nothing else.
        case exited
        /// The output broke the provider's own format (an event over its size limit).
        case malformed
    }

    public let kind: Kind
    /// The provider's words, as it gave them; for a person, never for the decision.
    public let message: String
    /// The HTTP status the provider stated for its API, when it did.
    public let apiStatus: Int?
    /// The result's subtype the provider stated (Claude: `error_max_turns`, `error_during_execution`).
    public let subtype: String?
    /// The command line's exit status, when it had exited.
    public let exitStatus: Int32?
    /// When the rate limit that refused the turn resets, when the provider said.
    public let resetsAt: Date?

    public init(kind: Kind, message: String, apiStatus: Int? = nil, subtype: String? = nil, exitStatus: Int32? = nil,
                resetsAt: Date? = nil) {
        self.kind       = kind
        self.message    = message
        self.apiStatus  = apiStatus
        self.subtype    = subtype
        self.exitStatus = exitStatus
        self.resetsAt   = resetsAt
    }

    public var errorDescription: String? { message }

    /// Whether the same turn may succeed later with nothing changed on this Mac: a rate limit, a service failure, a
    /// cut stream. Credentials, a refused request or a broken format need someone first.
    public var retryable: Bool {
        switch kind {
            case .rateLimited, .unavailable, .noResult: true
            case .auth, .apiError, .turnError, .exited, .malformed: false
        }
    }

    /// The kind an HTTP status of the provider's API stands for.
    public static func kind(apiStatus: Int) -> Kind {
        switch apiStatus {
            case 429: .rateLimited
            case 401, 403: .auth
            case 500...599: .unavailable
            default: .apiError
        }
    }
}
