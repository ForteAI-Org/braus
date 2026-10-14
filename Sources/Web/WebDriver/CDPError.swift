//
//  CDPError.swift
//  Braus
//

/// CDPError says why a DevTools command or the browser around it failed, so a caller can tell a
/// refusal from the browser (the command did nothing) from a lost connection (its effect is unknown).
public enum CDPError: Error, Sendable, Equatable {

    /// Chrome answered the command with an error: it was rejected and had no effect.
    case protocolError(method: String, code: Int, message: String)

    /// The connection closed before the answer arrived: the command may or may not have run.
    case connectionClosed(method: String)

    /// No answer within the deadline. The command may still run; it is not repeated.
    case timedOut(method: String, seconds: Double)

    /// The answer arrived but did not carry what the command promises.
    case malformedResult(method: String, detail: String)

    /// A script evaluated in the page threw; the description is the exception's.
    case scriptFailed(String)

    /// Chrome could not be started, or did not open its pipe.
    case launchFailed(String)
}
