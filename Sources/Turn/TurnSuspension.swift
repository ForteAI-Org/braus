import Foundation

/// SuspensionToken identifies exactly one episode of person control.
nonisolated public struct SuspensionToken: Sendable, Hashable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// TurnSuspended ends a running turn while retaining its session for the person.
nonisolated public struct TurnSuspended: Error, Sendable {
    public let token: SuspensionToken
    public init(token: SuspensionToken) { self.token = token }
}
