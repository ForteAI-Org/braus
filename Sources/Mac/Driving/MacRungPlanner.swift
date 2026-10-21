import CoreGraphics
import EngineCore
import Foundation
import MacDriver

/// MacAccessibilityStep is what the accessibility rung does to one element.
public enum MacAccessibilityStep: Sendable, Equatable {
    /// An action the element lists: `AXPress`, `AXPick`, `AXConfirm`, `AXScrollDownByPage`...
    case perform(String, on: MacTreeNode)
    /// `AXSelected` on a row, or its container's selection.
    case select(MacTreeNode)
    /// `AXMain` on the window and `AXFocused` on a field: a click on a field is a focus.
    case focus(MacTreeNode)
    /// One page in a scroll area, by its page action or its scroll bar.
    case scroll(MacTreeNode, MacScrollDirection)
}

/// MacRungPlan is the rung a gesture takes, decided from the scene before anything is sent.
public enum MacRungPlan: Sendable, Equatable {
    /// Rung 1, accessibility, no focus.
    case accessibility(MacAccessibilityStep)
    /// Rung 2, events posted to the process in place. `reason` says why rung 1 was skipped;
    /// `needsKeyWindow` asks for the seat's key-window records around the events.
    case events(reason: String, needsKeyWindow: Bool)
    /// No rung of the MacDriver delivers this gesture here.
    case refused(String)
}

/// MacRungPlanner chooses the rung for one gesture on one window's tree (spec section 3, the ladder).
/// Pure: the same tree and gesture give the same plan.
///
/// Rung 1 takes only actions the element lists: `AXPress` where the press is the click, `AXPick` on
/// pop-up and menu buttons, rows by selection, scroll by page, a field by focus; menu items only while
/// enabled. A click on a group, a cell or a text goes to its one actionable element. Never
/// `AXShowMenu`, `AXShowAlternateUI` or `AXRaise` (they bring the app to the front), never `AXValue` on
/// a text field. Everything else is rung 2 with its reason; a drag needs the seat (mode 1).
public enum MacRungPlanner {

    static let pressRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXSlider", "AXMenuItem",
        "AXIncrementor", "AXColorWell", "AXTab",
    ]
    static let pickRoles: Set<String> = ["AXPopUpButton", "AXMenuButton"]
    static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let passThroughRoles: Set<String> = ["AXGroup", "AXCell", "AXStaticText", "AXImage", "AXUnknown"]

    public static func plan(_ gesture: Gesture, at point: CGPoint, in window: MacTreeNode) -> MacRungPlan {
        switch gesture {
            case .click(_, let button, let count):
                if button == .right { return .events(reason: "right click: AXShowMenu brings the app to the front", needsKeyWindow: false) }
                if count > 1 { return .events(reason: "a \(count)-click has no accessibility action", needsKeyWindow: false) }
                guard let chain = chain(at: point, in: window) else {
                    return .events(reason: "no element of the scene under the point", needsKeyWindow: false)
                }
                return click(chain)
            case .scroll(_, let deltaY, let deltaX):
                guard let chain = chain(at: point, in: window),
                      let area = chain.last(where: { $0.role == "AXScrollArea" })
                else { return .events(reason: "no scroll area under the point", needsKeyWindow: false) }
                let direction: MacScrollDirection = deltaY != 0 ? (deltaY < 0 ? .down : .up) : (deltaX < 0 ? .right : .left)
                return .accessibility(.scroll(area, direction))
            case .key, .character, .type, .insert:
                return .events(reason: "keys have no accessibility action: posted to the process", needsKeyWindow: true)
            case .drag:
                return .refused("a drag needs the seat (mode 1)")
        }
    }

    /// The nodes from the window down to the smallest element under the point.
    static func chain(at point: CGPoint, in window: MacTreeNode) -> [MacTreeNode]? {
        func descend(_ node: MacTreeNode) -> [MacTreeNode]? {
            guard let frame = node.frame, frame.contains(point) else { return nil }
            let deeper = node.children.compactMap(descend).min { area(of: $0.last) < area(of: $1.last) }
            return [node] + (deeper ?? [])
        }
        return descend(window).flatMap { $0.count > 1 ? $0 : nil }
    }

    private static func area(of node: MacTreeNode?) -> CGFloat {
        guard let frame = node?.frame else { return .greatestFiniteMagnitude }
        return frame.width * frame.height
    }

    private static func click(_ chain: [MacTreeNode]) -> MacRungPlan {
        guard let target = chain.last else { return .events(reason: "no element under the point", needsKeyWindow: false) }
        if let plan = direct(target) { return plan }
        // A row, or anything inside one that does not act on its own, selects the row.
        if let row = chain.last(where: { $0.role == "AXRow" }) { return selectRow(row) }
        // A group, cell, text or image goes to its one actionable element, its own or its parent's.
        if passThroughRoles.contains(target.role) {
            let scopes = [target] + chain.dropLast().reversed().prefix(1).filter { passThroughRoles.contains($0.role) }
            for scope in scopes {
                let actionable = scope.flattened.dropFirst().filter { direct($0) != nil }
                if actionable.count == 1, let only = actionable.first, let plan = direct(only) { return plan }
            }
        }
        return .events(reason: "\(target.role) lists no AXPress", needsKeyWindow: false)
    }

    /// The plan for an element that acts on its own, or nil.
    private static func direct(_ node: MacTreeNode) -> MacRungPlan? {
        if node.role == "AXMenuItem", node.isEnabled == false {
            return .events(reason: "menu item disabled", needsKeyWindow: true)
        }
        if pickRoles.contains(node.role) {
            if node.actions.contains("AXPick") { return .accessibility(.perform("AXPick", on: node)) }
            if node.actions.contains("AXPress") { return .accessibility(.perform("AXPress", on: node)) }
            return nil
        }
        if fieldRoles.contains(node.role) { return .accessibility(.focus(node)) }
        if pressRoles.contains(node.role) || node.subrole == "AXSwitch" {
            if node.isEnabled == false { return .events(reason: "\(node.role) disabled", needsKeyWindow: true) }
            if node.actions.contains("AXPress") { return .accessibility(.perform("AXPress", on: node)) }
            return nil
        }
        if node.role == "AXRow" { return selectRow(node) }
        for action in ["AXConfirm", "AXPress"] where node.actions.contains(action) {
            return .accessibility(.perform(action, on: node))
        }
        return nil
    }

    private static func selectRow(_ row: MacTreeNode) -> MacRungPlan {
        .accessibility(.select(row))
    }
}
