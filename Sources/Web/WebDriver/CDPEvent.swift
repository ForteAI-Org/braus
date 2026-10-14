//
//  CDPEvent.swift
//  Braus
//

/// CDPEvent is one notification Chrome sent without being asked, such as `Page.loadEventFired`.
public struct CDPEvent: Sendable, Hashable {

    /// The protocol name, such as `DOM.documentUpdated`.
    public let method: String

    /// The notification's parameters, `.object([:])` when it has none.
    public let params: JSONValue

    /// The flattened session the event belongs to, nil for a browser level event.
    public let sessionID: String?

    public init(method: String, params: JSONValue, sessionID: String?) {
        self.method    = method
        self.params    = params
        self.sessionID = sessionID
    }
}
