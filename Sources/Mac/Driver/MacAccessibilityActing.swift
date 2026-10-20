import Foundation

/// MacElementAddress names one element of a window the way a scene read it: the process, the window's
/// index in `AXWindows` and its identity, the child path, and the role and own name the element had. Acting
/// resolves it again and refuses (`staleTarget`) when the window at that index is not the one the scene was read
/// from, or when the path no longer leads to that role and name.
public struct MacElementAddress: Sendable, Equatable {

    public var processID: pid_t
    public var windowIndex: Int
    public var path: [Int]
    public var role: String
    /// The element's own name (title, description, value, help or placeholder) when the scene had
    /// one; nil when its label came from elsewhere (a preceding text, a row's texts).
    public var name: String?
    /// Whether `path` comes from a visible-only read (a scene) or from a whole read.
    public var visibleOnly: Bool
    /// The window the scene was read from. Nil is the legacy address, made without a scene (`MacBackgroundOpener`)
    /// or from a reader that gives no identity: it acts by index alone, as before identities. Every address made from
    /// a live scene carries one.
    public var window: MacWindowIdentity?

    public init(
        processID  : pid_t,
        windowIndex: Int,
        path       : [Int],
        role       : String,
        name       : String? = nil,
        visibleOnly: Bool = true,
        window     : MacWindowIdentity? = nil
    ) {
        self.processID   = processID
        self.windowIndex = windowIndex
        self.path        = path
        self.role        = role
        self.name        = name
        self.visibleOnly = visibleOnly
        self.window      = window
    }

    /// Whether `current`, the window found at `windowIndex` now, is the window this address was read in: always for
    /// a legacy address, and never when it names a window and `current` is absent or another. Every accessibility
    /// request checks it before it is sent, live and fake alike.
    public func admits(_ current: MacWindowIdentity?) -> Bool {
        guard let window else { return true }
        return current == window
    }
}

public enum MacScrollDirection: String, Sendable, Equatable {
    case up, down, left, right

    var pageAction: String {
        switch self {
            case .up   : "AXScrollUpByPage"
            case .down : "AXScrollDownByPage"
            case .left : "AXScrollLeftByPage"
            case .right: "AXScrollRightByPage"
        }
    }
}

/// MacAccessibilityActing is the accessibility rung's hands: actions the element lists, selection,
/// focus without raise, and the element's read-back. Nothing here activates the app or raises a window.
/// Every call is `async`: the live actor runs it off the caller's actor (spec section 3, rule 3).
///
/// The call's stop (its task cancelled) is checked right before each write. Before the first write a call throws
/// `CancellationError`, and only there: nothing of it went out. A stop after a write went out, between focus's two,
/// is answered `MacTreeFailure.uncertain` and nothing is written again.
public protocol MacAccessibilityActing: Sendable {

    /// Performs an action the live element lists. Throws `staleTarget`, `actionNotListed` (read before the
    /// request: nothing was sent) or `uncertain` (the app timed out or answered an error: it may have acted).
    func perform(_ action: String, on element: MacElementAddress) async throws

    /// Selects the element: `AXSelected`, or its container's `AXSelectedRows` / `AXSelectedChildren`.
    func select(_ element: MacElementAddress) async throws

    /// Makes the window main and the element focused (`AXMain`, `AXFocused`), so keys posted to the
    /// process land in it. Never `AXRaise`.
    func focus(_ element: MacElementAddress) async throws

    /// Scrolls a scroll area by about one page: its scroll bar's `AXValue` when it has a bar, else its
    /// `AXScroll…ByPage` action (SwiftUI lists the actions, answers an error, and scrolls the other way:
    /// measured 15 Oct). Answers which of the two ran.
    @discardableResult
    func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) async throws -> String

    /// The element's attributes now, without children; nil when the path leads nowhere.
    func readBack(_ element: MacElementAddress) async -> MacTreeNode?
}
