import EngineCore
import Foundation

/// MacEventDelivering is the MacDriver's rung 2 (mode 2, in place): events posted to the process for a
/// window that stays where it is, the person's app staying in front. Nothing is posted globally and the
/// window is never raised.
public protocol MacEventDelivering: Sendable {

    /// Posts one gesture to the window, its points in global coordinates. With `needsKeyWindow` the
    /// seat's key-window records are sent to the target window first and restored right after (keys
    /// land in the app's key window; a command disabled while inactive enables, measured 14 Oct).
    /// Throws when mode 2 is refused on this build or the window has no attested identity; then
    /// nothing was posted. A restore that failed after the events went out is in the receipt, never thrown.
    func deliver(
        _ gesture     : Gesture,
        toWindow windowNumber: Int,
        of processID  : pid_t,
        needsKeyWindow: Bool
    ) async throws -> MacEventReceipt
}

/// MacEventReceipt is what rung 2 knows once a gesture's events went out.
public struct MacEventReceipt: Sendable, Equatable {

    /// True when the key-window records sent before the events could not be taken back: the app may
    /// treat the window as its key window until a later gesture prepares it again. The events did go
    /// out, so this is reported and never thrown, as the seat reports `preparationNotRestored`: a
    /// delivered gesture must not be replayed.
    public var preparationNotRestored: Bool

    public init(preparationNotRestored: Bool = false) {
        self.preparationNotRestored = preparationNotRestored
    }
}
