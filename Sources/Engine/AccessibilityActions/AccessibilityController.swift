//
//  AccessibilityController.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AccessibilityFacts
import ApplicationServices
import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// AccessibilityController fills `ControlPressing` with the live accessibility tree: it finds a
/// combo box or pop-up button by its value or title and presses it, reads the value of the one
/// control whose value is among a set of labels, reads a toggle's state under a point or by its
/// label, and reads the value of the text field that holds the application's focus.
///
/// The engine asks `pressControl` before every click, so the control reads and presses run off the
/// caller's actor, within a `WalkBudget`: a slow application blocks a global executor thread, not the
/// main actor. The menu reads and presses stay on the main actor with `DropdownOpening`. Geometry is
/// used only for the hit test under a point, never to relate a control to a pop-up: after a
/// window-server move the tree's frames are stale, and matching by value is what stays true.
public struct AccessibilityController: ControlPressing {

    private static let controlRoles: Set<String> = ["AXComboBox", "AXPopUpButton"]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]

    public init() {}

    /// Presses the first combo box or pop-up button labelled `label` that lists AXPress among its actions.
    ///
    /// The search covers every window of the application: `ControlPressing` names no window, so the
    /// press cannot be bound to the captured one as `DropdownOpening.Window` binds a dropdown.
    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        let want = LabelText.normalize(label)
        guard !want.isEmpty else { return false }
        return await Self.offMainActor {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: WalkBudget.standard.applicationTimeout)
            guard let control = Self.pressTarget(
                labelled: want,
                in      : reader.windows(of: application),
                reader  : reader,
                timeout : { reader.setMessagingTimeout($0, seconds: WalkBudget.standard.elementTimeout) }
            ) else { return false }
            // A timed-out press may have reached the app: false would make the engine click it again.
            let result = AXUIElementPerformAction(control, kAXPressAction as CFString)
            return result == .success || result == .cannotComplete
        }
    }

    public func menuItemNavigation(
        titled title: String,
        within menuFrame: CGRect,
        in processID: pid_t
    ) async -> MenuItemNavigation? {
        await MainActor.run {
            DropdownOpening.navigation(item: title, in: menuFrame, processID: processID)
        }
    }

    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        await MainActor.run {
            do {
                try DropdownOpening.select(item: title, in: menuFrame, processID: processID)
                return true
            } catch DropdownOpening.Failure.actionRefused {
                return true
            } catch {
                return false
            }
        }
    }

    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        guard !labels.isEmpty else { return nil }
        return await Self.offMainActor {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: WalkBudget.standard.applicationTimeout)
            var matches: [String] = []
            let complete = Self.walk(
                reader.windows(of: application),
                reader : reader,
                timeout: { reader.setMessagingTimeout($0, seconds: WalkBudget.standard.elementTimeout) }
            ) { node in
                guard Self.controlRoles.contains(reader.role(node) ?? ""), let value = reader.value(node) else {
                    return false
                }
                if labels.contains(LabelText.normalize(value)) { matches.append(value) }
                return false
            }
            return complete && matches.count == 1 ? matches[0] : nil
        }
    }

    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        await Self.offMainActor {
            let reader = LiveAccessibilityReader()
            var element: AXUIElement?
            let system = AXUIElementCreateSystemWide()
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
                  let element else { return nil }
            switch reader.numericValue(element) {
                case 0 : return .off
                case 1 : return .on
                case 2 : return .mixed
                default: return nil
            }
        }
    }

    public func toggleState(labelled label: String, in processID: pid_t) async -> ControlState? {
        let want = LabelText.normalize(label)
        guard !want.isEmpty else { return nil }
        return await Self.offMainActor {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: WalkBudget.standard.applicationTimeout)
            var states: [ControlState?] = []
            let complete = Self.walk(
                reader.windows(of: application),
                reader : reader,
                timeout: { reader.setMessagingTimeout($0, seconds: WalkBudget.standard.elementTimeout) }
            ) { node in
                guard Self.toggleRoles.contains(reader.role(node) ?? ""),
                      LabelText.normalize(reader.title(node) ?? "") == want
                        || LabelText.normalize(reader.descriptionText(node) ?? "") == want
                else { return false }
                let state: ControlState? = switch reader.numericValue(node) {
                    case 0 : .off
                    case 1 : .on
                    case 2 : .mixed
                    default: nil
                }
                states.append(state)
                return false
            }
            return complete && states.count == 1 ? states[0] : nil
        }
    }

    public func focusedFieldValue(in processID: pid_t) async -> String? {
        await Self.offMainActor {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: WalkBudget.standard.applicationTimeout)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
                    == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            // The type id was checked one line up; a Swift cast cannot see through a CF type here.
            let field = unsafeDowncast(focused, to: AXUIElement.self)
            guard Self.fieldRoles.contains(reader.role(field) ?? "") else { return nil }
            return reader.value(field)
        }
    }

    // MARK: Off the main actor

    /// Runs `body` on the global executor, so an application that answers slowly holds this thread
    /// within the walk's budget and never the caller's actor.
    @concurrent
    private static func offMainActor<Value: Sendable>(_ body: @Sendable () -> Value) async -> Value {
        body()
    }

    // MARK: Walk

    /// WalkBudget bounds one walk, so a dense or hung application answers in time with an incomplete
    /// answer instead of holding the caller: elements visited, depth from a window, monotonic wall time,
    /// and the messaging timeouts set on the application element and on every element visited.
    struct WalkBudget: Equatable {
        var elements          : Int
        var depth             : Int
        var deadline          : Duration
        var applicationTimeout: Float
        var elementTimeout    : Float

        // Chosen for dense mixers: a mixer window shows hundreds of scene elements over a larger tree,
        // so the limit stays far above it and a walk is cut only by an app that never answers.
        static let standard = WalkBudget(
            elements          : 4_000,
            depth             : 10,
            deadline          : .seconds(3),
            applicationTimeout: 1,
            elementTimeout    : 0.25
        )
    }

    static func firstControl<Reader: AccessibilityTreeReading>(
        in roots: [Reader.Node],
        reader  : Reader,
        budget  : WalkBudget = .standard,
        timeout : (Reader.Node) -> Void = { _ in },
        where predicate: (Reader.Node) -> Bool
    ) -> Reader.Node? {
        var found: Reader.Node?
        walk(roots, reader: reader, budget: budget, timeout: timeout) { node in
            guard controlRoles.contains(reader.role(node) ?? ""), predicate(node) else { return false }
            found = node
            return true
        }
        return found
    }

    /// The first control whose normalized value or title is `want` and that lists AXPress. A control
    /// that does not list it is skipped, since the press would be refused or mean something else.
    static func pressTarget<Reader: AccessibilityTreeReading>(
        labelled want: String,
        in roots     : [Reader.Node],
        reader       : Reader,
        budget       : WalkBudget = .standard,
        timeout      : (Reader.Node) -> Void = { _ in }
    ) -> Reader.Node? {
        firstControl(in: roots, reader: reader, budget: budget, timeout: timeout) { node in
            (LabelText.normalize(reader.value(node) ?? "") == want
                || LabelText.normalize(reader.title(node) ?? "") == want)
                && reader.actions(node).contains(kAXPressAction)
        }
    }

    /// Visits the nodes under the roots depth first, to `budget.depth` levels, until `visit` returns true.
    /// `timeout` is given each node before it is read. Answers false when a node's children did not answer
    /// (`readChildren`, M2) or the budget's elements or deadline ran out: what the walk saw is then not
    /// the whole tree. `firstControl` ignores the answer: it presses the first match, which never claimed
    /// to be the only one.
    @discardableResult
    static func walk<Reader: AccessibilityTreeReading>(
        _ roots: [Reader.Node],
        reader : Reader,
        budget : WalkBudget = .standard,
        timeout: (Reader.Node) -> Void = { _ in },
        visit  : (Reader.Node) -> Bool
    ) -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: budget.deadline)
        var visited = 0
        var stop = false
        var incomplete = false
        func descend(_ node: Reader.Node, _ depth: Int) {
            guard !stop, depth <= budget.depth else { return }
            guard visited < budget.elements, clock.now < end else { stop = true; incomplete = true; return }
            visited += 1
            timeout(node)
            if visit(node) { stop = true; return }
            guard let children = reader.readChildren(node) else { incomplete = true; return }
            for child in children { descend(child, depth + 1) }
        }
        for root in roots { descend(root, 0) }
        return !incomplete
    }
}
