import CoreGraphics
import SeatCore
import SeatSession

/// HeldWindow describes one held application window on the virtual display.
/// Its frame uses WindowServer coordinates, and order is zero-based, front to back.
nonisolated public struct HeldWindow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case main, dialog, sheet, panel, other

        /// AX facts take precedence; only the floating-window levels supply a fallback.
        static func classify(role: String?, subrole: String?, level: Int) -> Kind {
            if role == "AXSheet" { return .sheet }
            if subrole == "AXDialog" || subrole == "AXSystemDialog" { return .dialog }
            if role == "AXDrawer" || subrole == "AXFloatingWindow" || subrole == "AXSystemFloatingWindow" {
                return .panel
            }
            if subrole == "AXStandardWindow" { return .main }
            if level == 3 || level == 4 { return .panel }
            return .other
        }
    }

    public let windowNumber: Int
    public let processID: Int32
    public let frame: CGRect
    public let level: Int
    public let kind: Kind
    public let parentWindowNumber: Int?
    public let title: String
    public let order: Int

    init(surface: WindowSurface, metadata: WindowPresentationMetadata?, order: Int) {
        windowNumber = surface.reference.windowNumber
        processID = surface.reference.processID
        frame = surface.reference.frame
        level = surface.level
        kind = Kind.classify(role: metadata?.role, subrole: metadata?.subrole, level: surface.level)
        parentWindowNumber = metadata?.parentWindowNumber
        title = metadata?.title ?? ""
        self.order = order
    }
}
