import Foundation

/// CapabilityCallContext carries the session identity borrowed by one registered call.
public struct CapabilityCallContext: Sendable {
    public let sessionID: UUID?

    public init(sessionID: UUID?) { self.sessionID = sessionID }
}
