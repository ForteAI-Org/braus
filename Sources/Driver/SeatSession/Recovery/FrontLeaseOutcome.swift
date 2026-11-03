//
//  FrontLeaseOutcome.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

/// FrontLeaseOutcome is what `AgentSeat.lendFront` did with the front: how the
/// lease ended and whether the front went back to the person, or why nothing
/// was lent at all. What the body returned or threw travels beside it.
///
/// The durations run from the request that brought the target in front to the
/// end of the body, on the seat's monotonic clock, in whole milliseconds. Only
/// `completed` and `boundReached` say the handback was verified: an unverified
/// handback is `handbackNotVerified` whatever the body did.
nonisolated public enum FrontLeaseOutcome: Sendable, Equatable {

    /// The body returned on its own, and the handback to the person's attested
    /// window was verified.
    case completed(afterMilliseconds: Int)

    /// The bound passed first: the body was cancelled, the lease waited for it
    /// to return, and the handback was verified. Nothing was retried.
    case boundReached(afterMilliseconds: Int)

    /// Another process held the front before the handback, the person's
    /// choice: a running body was cancelled, and the front was left where it
    /// was. Nothing was handed back over it.
    case frontTaken(afterMilliseconds: Int)

    /// The target was not seen in front within the wait for it, so the body
    /// never ran. A front the target took late was still handed back.
    case neverInFront(afterMilliseconds: Int)

    /// The handback to the person's attested window was not verified within
    /// two seconds. If the target still holds foreground, ordinary focus
    /// recovery owns the episode. The body's result stands either way.
    case handbackNotVerified

    /// The seat refused, and says why, with the brief activation's reasons.
    /// Nothing was brought in front and the body never ran, except for
    /// `frontRequestRefused`, whose front is handed back if it moved anyway.
    case refused(BriefActivationOutcome.Refusal)
}
