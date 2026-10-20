import LocalMCP

/// ToolCallOutcome records how Braus decided consent for a tool call, with the answer for the model.
/// Only the host produces this decision; a tool's answer, error or text never grants consent.
public enum ToolCallOutcome: Sendable, Equatable {
    /// Not decided by the person: no such tool, arguments that do not fit, or stopped before sending for a reason that
    /// is not theirs (the tool or its kind changed, a cancellation, a connection that failed before the last check).
    /// Nothing was sent.
    case notDecided(JSONValue)
    /// The consent let the call go (allowed, or asked and approved), and the decision right before sending held for
    /// the definition it sent: it was sent, or its sending failed; the answer says which.
    case consented(JSONValue)
    /// The person refused it: their settings deny it, they did not approve it when asked (or no one could be
    /// asked), or they changed their settings to refuse it before it was sent. Nothing was sent.
    case refusedByPerson(JSONValue)

    public var answer: JSONValue {
        switch self {
            case .notDecided(let answer), .consented(let answer), .refusedByPerson(let answer): answer
        }
    }
}
