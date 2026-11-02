//
//  SessionFrontOutcome.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

/// SessionFrontOutcome tells a tool how borrowing the held application's front ended,
/// independently of the command's result and without exposing Driver types.
nonisolated public enum SessionFrontOutcome: Sendable, Equatable {

    /// The command ended on its own and the handback to the person was verified.
    case completed

    /// The time limit cancelled the command and the handback was verified.
    case boundReached

    /// The handback was not verified; any command effects still stand.
    case handbackNotVerified

    /// The person took the front, which was left with their choice.
    case frontTaken

    /// The application was never verified in front, so the command did not run.
    case neverInFront

    /// The Seat refused the lease, with a sentence the tool can show the model.
    case refused(reason: String)

    /// This session does not hold the requested application on a Seat; the command did not run.
    case notHeld

    /// Whether the lease completed on its own with a verified handback.
    /// The caller must also inspect the command's separate result before reporting command success.
    public var isSuccess: Bool { self == .completed }

    /// One sentence describing the lease, suitable for a tool's answer to the model.
    public var reason: String {
        switch self {
            case .completed:
                return "The application borrowed the front and the return to the person's window was verified."
            case .boundReached:
                return "The time limit cancelled the command and the return to the person's window was verified."
            case .handbackNotVerified:
                return "The return to the person's window was not verified, so the lease is not a success and any "
                    + "command effects must not be retried automatically."
            case .frontTaken:
                return "The person took the front, and their choice was left in front."
            case .neverInFront:
                return "The application was never verified in front, so the command did not run."
            case .refused(let reason):
                return reason
            case .notHeld:
                return "This session does not hold that application on a Seat, so the command did not run."
        }
    }
}
