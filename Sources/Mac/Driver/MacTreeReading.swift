import Foundation

/// MacTreeReading reads an application's windows through the accessibility API, with the app
/// behind and without activating it. Every call reads the present moment; nothing is cached.
///
/// Every read that messages the app is `async`: the live reader runs it off the caller's actor, so no
/// caller can hold Braus's main actor on a slow app (spec section 3, rule 3). `isTrusted` asks only
/// this process.
public protocol MacTreeReading: Sendable {

    /// Whether this process may read other apps' accessibility trees. Never prompts.
    var isTrusted: Bool { get }

    /// The app's windows, front to back, without their trees.
    func windows(of processID: pid_t) async throws -> [MacWindowSummary]

    /// One window's tree, its sheets included, within `limits`. The window is the one `windows`
    /// listed at `index`; a window that is gone throws `MacTreeFailure.windowNotFound`.
    func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) async throws -> MacTreeRead
}

public enum MacTreeFailure: Error, Equatable, Sendable {
    case notTrusted
    case applicationUnreachable(pid_t)
    case windowNotFound(index: Int)
    /// The window itself, or the list of its children, did not answer, or the read's budget ran out before the window
    /// was read (`timedOut`): nothing of it was read.
    case windowUnreadable(index: Int, cause: MacReadFailure)
    case elementNotFound(path: [Int])
    /// The path leads to another element than the scene showed: re-read before acting.
    case staleTarget(path: [Int])
    /// The element does not list this action now (14 Oct: `AXPress` on an element without it returned
    /// success and did nothing, so an unlisted action is never sent).
    case actionNotListed(String)
    /// The app answered an error to a request it received. Whether it acted is not known, so the actuator takes it as
    /// uncertain and never replays it on another rung (R06); the live reader answers `uncertain` itself.
    case actionFailed(String)
    /// The app did not answer in time: the action may or may not have run. Never retried on another rung.
    case uncertain(String)
}
