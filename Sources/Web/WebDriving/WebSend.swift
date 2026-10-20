//
//  WebSend.swift
//  Braus
//

import Foundation

/// WebSend is what the web actuator knows of the last gesture it started sending to a tab (M05): the DevTools `Input`
/// method the gesture is made of, how many commands it is, how many were handed to the connection, how many the
/// browser acknowledged, and how the sequence ended. A fixed name and counts, no text of the page's or the person's.
/// A command handed to the connection is not one on the wire (the connection throws before its transport sends when
/// it is closed), an acknowledgement is not an effect, and none acknowledged is not none.
public struct WebSend: Sendable, Equatable, CustomStringConvertible {

    public enum Method: String, Sendable, Equatable {
        case mouse      = "Input.dispatchMouseEvent"
        case key        = "Input.dispatchKeyEvent"
        case insertText = "Input.insertText"
    }

    public enum Outcome: String, Sendable, Equatable {
        /// Every command was answered.
        case completed
        /// The browser answered a command with an error: it had no effect, and the sequence stopped there.
        case rejectedByBrowser = "rejected by the browser"
        /// A command got no answer: the connection closed, the deadline passed, the call was cancelled, or another
        /// failure; whether it ran is not known, and the sequence stopped there.
        case unanswered
    }

    public let method      : Method
    public let planned     : Int
    public let attempted   : Int
    public let acknowledged: Int
    public let outcome     : Outcome

    public init(method: Method, planned: Int, attempted: Int, acknowledged: Int, outcome: Outcome) {
        self.method       = method
        self.planned      = planned
        self.attempted    = attempted
        self.acknowledged = acknowledged
        self.outcome      = outcome
    }

    /// The send as the record words it: the method, the three counts, the outcome.
    public var description: String {
        "\(method.rawValue): \(planned) planned, \(attempted) attempted, \(acknowledged) acknowledged, \(outcome.rawValue)"
    }
}
