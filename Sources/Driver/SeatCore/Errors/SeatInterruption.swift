//
//  SeatInterruption.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// SeatInterruption is thrown when one or more Issues stop an operation. It
/// carries the Issues themselves rather than a message, so the caller can tell
/// a suspension from a failure without parsing anything; the sentence for the
/// person is the consumer's to write.
public struct SeatInterruption: Error, Sendable, Equatable {

    /// The Issues that stopped the operation, in detection order.
    public let issues: [SeatIssue]

    /// True when the preflight stopped the Command before any of its events
    /// went out, so nothing it would have done can have happened. False says
    /// nothing either way: an Issue read after an event is never this one.
    public let beforeAnyEvent: Bool

    public init(issues: [SeatIssue], beforeAnyEvent: Bool = false) {
        self.issues = issues
        self.beforeAnyEvent = beforeAnyEvent
    }

    /// True when at least one Issue is critical. A recoverable Issue hidden in
    /// the same batch never softens a critical one.
    public var isCritical: Bool {
        issues.contains(where: \.isCritical)
    }
}
