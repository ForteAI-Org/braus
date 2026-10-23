//
//  IrreversiblePolicy.swift
//  Braus
//

import Foundation

/// IrreversiblePolicy is rule 4 of the routing design (2026-10-14-mac-driver-design, section 2): a destructive or
/// irreversible step (send, delete, pay) runs only when the person allowed destructive actions and the route has a
/// verifier of that step's own effect. The person's consent is necessary and never sufficient, and neither a route
/// nor reading a scene or a page again is proof: on 14 Oct Mail's "Invia" reported success, closed its window and
/// saved a draft, and a web send can close its dialog the same way. Today only an adapter verb that reads its change
/// back, under its declared contract, confirms; the engine's routes, native, seat and web, do not.
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
        "\(what) looks destructive or irreversible, and this route cannot read its effect back: refused, not "
            + "authorized in this session on this route, whatever the person allows. Send, delete or pay through an adapter verb that reads its effect back (app_call)."
    }
}
