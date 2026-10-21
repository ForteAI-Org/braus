//
//  CallRouteAdvice.swift
//  Braus
//

/// CallRouteAdvice is the router's decision an `open_session` answered with its words (M05): `use`, with the address of
/// the route it named (`web:<host>`, `app_call(<adapter>)`, …) and its message, instead of opening;
/// `ask`, with its question, instead of opening; or `open`, the decision to open the app as asked, with the note the
/// router gave with it (why the interface is driven instead of an adapter this build lacks or that cannot run, or the
/// advice on a contact's channel). It is a decision and its words, never a dispatch: `use` and `ask` opened nothing,
/// so they have no route row, no scene, no effect and no rung; `open` is the decision, not the opening's success: the
/// route row says where the call really went and the call's own result says how it ended, and the note is kept even
/// when the opening then fails. Handed by the tools to the call's current recorder before anything opens, written once
/// with the call's end, its address and words minimized as every text of the call is. An `open` with no note, and a
/// call refused before the router, have none.
public struct CallRouteAdvice: Sendable, Equatable {

    public enum Decision: String, Sendable, Equatable, Hashable, CaseIterable {
        case use, ask, open
    }

    public let decision: Decision
    /// The route's address for `use`; nil for `ask` and `open`.
    public let route: String?
    /// The message of a `use`, the question of an `ask`, the note of an `open`.
    public let message: String

    public init(decision: Decision, route: String?, message: String) {
        self.decision = decision
        self.route    = route
        self.message  = message
    }
}
