//
//  FrontLeaseInput.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import SeatCore

/// FrontLeaseInput is how the body of `AgentSeat.lendFront` clicks in the lent
/// application: through the seat's own per-process route, `CGEventPostToPid`
/// with the driver's Preparation where the platform needs one, and never
/// through the HID stream, so the person's pointer does not move.
///
/// The HID route cannot carry it. Measured on 02/11/2026 with a DAW held by the
/// seat, five runs: inside a front lease the application is truly frontmost on
/// the virtual display and keys posted at the HID tap reach it, but clicks
/// never do. `CursorFence` rewrites every HID mouse event outside the person's
/// displays to the nearest allowed pixel and drops a press that started there:
/// a click posted at the centre of an empty playlist lane (3471, 2084) left the
/// pointer at the main display's corner (1511, 981) 40 ms later and changed
/// nothing in the application, two of its counters read the same before and
/// after.
///
/// A click goes to the window of the lent process under the point, read from
/// the window server at call time, so a window, panel or pop-up menu the
/// application opened during the lease counts as its own. A point that is not
/// on such a window on the virtual display is refused with nothing posted.
/// Every call is one attempt and is never retried; it throws, posting nothing,
/// once the lease has ended or the calling task is cancelled.
///
/// The events carry a marker of the lease's own, which the seat's command gate
/// admits for the lease alone. They never pass the fence's tap, which sees
/// the HID stream only, so neither its anchors nor its audit see them.
@MainActor
public final class FrontLeaseInput {

    /// What one click posted: the process and the window it was routed to,
    /// the screen point, and the driver's Receipt.
    public struct Receipt: Sendable, Equatable {
        public let processID   : Int32
        public let windowNumber: Int
        public let location    : CGPoint
        public let input       : InputReceipt
    }

    /// Why a click was refused before anything was posted.
    public enum Refusal: Error, Sendable, Equatable {

        /// The lease this input belongs to has ended.
        case leaseEnded

        /// No window of the lent application on the virtual display is under
        /// the point.
        case outsideApplication(CGPoint)

        /// The window server did not answer which windows the application shows.
        case windowsUnreadable
    }

    /// The lent application's process.
    public let processID: Int32

    /// The correlation marker stamped on every event of this lease.
    let marker: Int64

    private weak var seat: AgentSeat?
    private var hasEnded = false

    init(
        seat     : AgentSeat,
        processID: Int32,
        marker   : Int64
    ) {
        self.seat      = seat
        self.processID = processID
        self.marker    = marker
    }

    /// True while the lease runs and the calling task is not cancelled: a
    /// click now would be attempted.
    public var isActive: Bool { !hasEnded && !Task.isCancelled && seat != nil }

    /// Clicks the left button `count` times at `point`, in global screen
    /// coordinates, with `modifiers` held on every down and up.
    @discardableResult
    public func click(
        at point : CGPoint,
        count    : Int = 1,
        modifiers: Modifiers = []
    ) async throws -> Receipt {
        try await post(
            at       : point,
            button   : .left,
            count    : count,
            modifiers: modifiers
        )
    }

    /// Clicks the right button once at `point`, in global screen coordinates,
    /// with `modifiers` held on the down and the up.
    @discardableResult
    public func rightClick(
        at point : CGPoint,
        modifiers: Modifiers = []
    ) async throws -> Receipt {
        try await post(
            at       : point,
            button   : .right,
            count    : 1,
            modifiers: modifiers
        )
    }

    /// Throws unless a click may still be attempted.
    func requireActive() throws {
        try Task.checkCancellation()
        guard !hasEnded, seat != nil else { throw Refusal.leaseEnded }
    }

    /// Ends the input with its lease. Every later call throws.
    func end() { hasEnded = true }

    private func post(
        at point : CGPoint,
        button   : MouseButton,
        count    : Int,
        modifiers: Modifiers
    ) async throws -> Receipt {
        try requireActive()
        guard let seat else { throw Refusal.leaseEnded }
        return try await seat.clickInFrontLease(
            self,
            at       : point,
            button   : button,
            count    : count,
            modifiers: modifiers
        )
    }
}
