//
//  WindowClosureFacts.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import CoreGraphics
import SeatCore

/// WindowClosureFacts is what the seat knows about the window an action targets that decides one
/// question: may closing it end the application?
///
/// Measured on 12/10/2026 with DaVinci Resolve: with no project open, its Project Manager is the
/// application's only accessibility window, has no main window and no cancel button, and Escape
/// closes it and Resolve quits. With a project open the editor is a standard main window with a close
/// button, and Escape there is harmless. The rule reads those facts and never the application's name.
///
/// ## The rule
///
/// It holds when all of these do, and the fail closed branch applies only below the role check:
/// - the application is a regular one, because an accessory application has no window it lives by;
///   an activation policy that could not be read counts as regular;
/// - the window is not a document: a document window is where a person works and closing it is theirs;
/// - the window is the application's only one, by accessibility (`AXWindows`) and by the window server
///   (visible windows of the process at ordinary layers, on any display, the virtual one included);
/// - the application has no main window, or the window has an `AXCancelButton`: a dialog that can be
///   cancelled is a dialog whose Escape cancels it.
///
/// A count or a main window reading that could not be taken counts as true, because the cost of a
/// wrong refusal is one sentence and the cost of a wrong delivery is the person's open application.
/// Stage Manager and windows on other Spaces are not in the window server's on-screen list, so a
/// process whose other windows sit there reads as having one window, which errs toward refusing.
///
/// The window being a menu or a popup open is not part of this type: the engine, which reads the
/// surfaces right before the key, ignores the rule while one is open.
nonisolated public struct WindowClosureFacts: Sendable, Equatable {

    /// The smallest side, in points, of a window server window that counts as a window of the
    /// application: the same size the seat applies when it lists an application's windows.
    package static let minimumWindowSide: CGFloat = 120

    /// The first window level that is a menu, a status item or an overlay rather than a window.
    package static let firstNonWindowLevel = 24

    package let role                    : SurfaceRole?
    package let accessibilityWindowCount: Int?
    package let onScreenWindowCount     : Int?
    package let hasMainWindow           : Bool?
    package let hasCancelButton         : Bool?
    package let isRegularApplication    : Bool?

    /// The screen rectangles of the window's `AXCancelButton` and `AXCloseButton`, when it has them.
    public let controlFrames: [CGRect]

    package init(
        role                    : SurfaceRole?,
        accessibilityWindowCount: Int?,
        onScreenWindowCount     : Int?,
        hasMainWindow           : Bool?,
        hasCancelButton         : Bool?,
        isRegularApplication    : Bool?,
        controlFrames           : [CGRect] = []
    ) {
        self.role                     = role
        self.accessibilityWindowCount = accessibilityWindowCount
        self.onScreenWindowCount      = onScreenWindowCount
        self.hasMainWindow            = hasMainWindow
        self.hasCancelButton          = hasCancelButton
        self.isRegularApplication     = isRegularApplication
        self.controlFrames            = controlFrames
    }

    /// True when closing the window may end the application.
    public var mayEndTheApplication: Bool {
        guard isRegularApplication != false, role != .document else { return false }
        guard let accessibilityWindowCount, let onScreenWindowCount, let hasMainWindow else { return true }
        guard accessibilityWindowCount <= 1, onScreenWindowCount <= 1 else { return false }
        return !hasMainWindow || hasCancelButton != false
    }

    /// How many of `surfaces` are windows of the application: visible, at an ordinary level (a
    /// negative one is the desktop's, like Finder's) and not a sliver. `nil` surfaces are a reading
    /// that failed, which is not an empty application.
    package static func countedWindows(in surfaces: [WindowSurface]?) -> Int? {
        surfaces?.filter {
            $0.isVisible
                && (0 ..< firstNonWindowLevel).contains($0.level)
                && min($0.reference.frame.width, $0.reference.frame.height) >= minimumWindowSide
        }.count
    }
}
