//
//  IrreversiblePolicy.swift
//  Braus
//

import Foundation

/// IrreversiblePolicy decides whether a destructive or irreversible step (send, delete, pay) may run: only when the
/// person allowed it and the route has a verifier of that step's own effect. The person's consent is
/// necessary and never sufficient, and reading a scene again is no proof: a mail client's send button can report
/// success, close its window and save a draft. Today only an adapter verb that reads its change back, under its
/// declared contract, confirms, and only `AppAdapters` consults this policy.
/// `ActionPolicy` names what is destructive; this decides whether it may run where it was asked.
public enum IrreversiblePolicy {

    /// ReadBack is whether a route can confirm an irreversible step's effect by reading it back.
    public enum ReadBack: String, Sendable, Equatable, Codable {
        case confirms
        case cannotConfirm = "cannot_confirm"
    }

    /// Decision is what may happen to a destructive or irreversible step.
    public enum Decision: Sendable, Equatable {
        case allowed
        /// The person has not allowed it, or nobody can ask them.
        case needsConsent
        /// Consent or not, this route cannot read the effect back.
        case cannotReadBack
    }

    /// The decision for a destructive or irreversible step: consent first, then the route's read-back.
    public static func decision(allowed: Bool, readBack: ReadBack) -> Decision {
        guard allowed else { return .needsConsent }
        return readBack == .confirms ? .allowed : .cannotReadBack
    }

    /// The refusal of `what` on a route that cannot read its effect back, in the same words wherever it is said.
    public static func readBackRefusal(_ what: String) -> String {
        "\(what) looks destructive or irreversible, and this route cannot read its effect back: refused, whatever "
            + "the person allows. Send, delete or pay through an adapter verb that reads its effect back (app_call)."
    }
}
