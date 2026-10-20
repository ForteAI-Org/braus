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
/// The engine asks `pressControl` before every click, so a slow app must never hold the caller: every
/// read and press runs off the caller's actor (`@concurrent`), with a messaging timeout on each element
/// and a budget on each walk (`WalkBudget`). A walk on Notes, one request per attribute and none of
/// that, held the main actor about 10 s per click (15 Oct, #47). Geometry is used only for the hit test under a point, never to
/// relate a control to a pop-up: after a window-server move the tree's frames are stale, and matching
/// by value is what stays true.
public struct AccessibilityController: ControlPressing {

    private static let controlRoles: Set<String> = ["AXComboBox", "AXPopUpButton"]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton"]

    /// WalkBudget bounds one walk, so a dense app answers in time with a partial answer instead of
    /// not at all: elements visited, depth from a window, and wall time.
    public struct WalkBudget: Sendable, Equatable {
        public var elements: Int
        public var depth: Int
        public var deadline: Duration
        /// Messaging timeout on the application element, then on every other element, in seconds.
        public var applicationTimeout: Float
        public var elementTimeout: Float

        public init(elements: Int = 4_000, depth: Int = 10, deadline: Duration = .seconds(3),
                    applicationTimeout: Float = 1, elementTimeout: Float = 0.25) {
            self.elements           = elements
            self.depth              = depth
            self.deadline           = deadline
            self.applicationTimeout = applicationTimeout
            self.elementTimeout     = elementTimeout
        }

        public static let standard = WalkBudget()
    }

    public let budget: WalkBudget

    public init(budget: WalkBudget = .standard) {
        self.budget = budget
    }

    /// Presses the first combo box or pop-up button labelled `label` that lists AXPress among its actions.
    ///
    /// The search covers every window of the application: `ControlPressing` names no window, so the
    /// press cannot be bound to the captured one as `DropdownOpening.Window` binds a dropdown.
    public func pressControl(labelled label: String, in processID: pid_t) async -> Bool {
        let want = LabelText.normalize(label)
        guard !want.isEmpty else { return false }
        return await Self.pressControl(want, processID, budget, reader: Self.reader())
    }

    public func menuItemNavigation(
        titled title: String,
        within menuFrame: CGRect,
        in processID: pid_t
    ) async -> MenuItemNavigation? {
        await Self.menuItemNavigation(title, menuFrame, processID)
    }

    public func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        await Self.pressMenuItem(title, menuFrame, processID)
    }

    public func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? {
        guard !labels.isEmpty else { return nil }
        return await Self.controlValue(labels, processID, budget, reader: Self.reader())
    }

    public func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? {
        await Self.toggleState(point, budget, reader: Self.reader())
    }

    public func toggleState(labelled label: String, in processID: pid_t) async -> ControlState? {
        let want = LabelText.normalize(label)
        guard !want.isEmpty else { return nil }
        return await Self.toggleState(labelled: want, processID, budget, reader: Self.reader())
    }

    public func focusedFieldValue(in processID: pid_t) async -> String? {
        await Self.focusedFieldValue(processID, budget, reader: Self.reader())
    }

    // MARK: Off the caller's actor

    private static func reader() -> LiveAccessibilityReader { LiveAccessibilityReader() }

    /// The menu's reading runs off the caller's actor too: a slow application never holds it.
    @concurrent
    private static func menuItemNavigation(_ title: String, _ menuFrame: CGRect, _ processID: pid_t) async
        -> MenuItemNavigation? {
        DropdownOpening.navigation(item: title, in: menuFrame, processID: processID)
    }

    @concurrent
    private static func pressMenuItem(_ title: String, _ menuFrame: CGRect, _ processID: pid_t) async -> Bool {
        do {
            try DropdownOpening.select(item: title, in: menuFrame, processID: processID)
            return true
        } catch DropdownOpening.Failure.actionRefused {
            return true
        } catch {
            return false
        }
    }

    @concurrent
    private static func pressControl(_ want: String, _ processID: pid_t, _ budget: WalkBudget,
                                     reader: LiveAccessibilityReader) async -> Bool {
        let application = reader.application(processID: processID)
        reader.setMessagingTimeout(application, seconds: budget.applicationTimeout)
        guard let control = pressTarget(labelled: want, in: reader.windows(of: application), reader: reader, budget: budget,
                                        timeout: { reader.setMessagingTimeout($0, seconds: budget.elementTimeout) }) else { return false }
        // A timeout may have opened the list: answering false would make the engine click it shut.
        let result = AXUIElementPerformAction(control, kAXPressAction as CFString)
        return result == .success || result == .cannotComplete
    }

    @concurrent
    private static func controlValue(_ labels: Set<String>, _ processID: pid_t, _ budget: WalkBudget,
                                     reader: LiveAccessibilityReader) async -> String? {
        let application = reader.application(processID: processID)
        reader.setMessagingTimeout(application, seconds: budget.applicationTimeout)
        return controlValue(matchingAny: labels, in: reader.windows(of: application), reader: reader, budget: budget,
                            timeout: { reader.setMessagingTimeout($0, seconds: budget.elementTimeout) })
    }

    @concurrent
    private static func toggleState(_ point: CGPoint, _ budget: WalkBudget, reader: LiveAccessibilityReader) async -> ControlState? {
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        reader.setMessagingTimeout(element, seconds: budget.elementTimeout)
        switch reader.numericValue(element) {
            case 0 : return .off
            case 1 : return .on
            case 2 : return .mixed
            default: return nil
        }
    }

    @concurrent
    private static func toggleState(labelled want: String, _ processID: pid_t, _ budget: WalkBudget,
                                    reader: LiveAccessibilityReader) async -> ControlState? {
        let application = reader.application(processID: processID)
        reader.setMessagingTimeout(application, seconds: budget.applicationTimeout)
        return toggleState(labelled: want, in: reader.windows(of: application), reader: reader, budget: budget,
                           timeout: { reader.setMessagingTimeout($0, seconds: budget.elementTimeout) })
    }

    @concurrent
    private static func focusedFieldValue(_ processID: pid_t, _ budget: WalkBudget, reader: LiveAccessibilityReader) async -> String? {
        let application = reader.application(processID: processID)
        reader.setMessagingTimeout(application, seconds: budget.applicationTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        // The type id was checked one line up; a Swift cast cannot see through a CF type here.
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        reader.setMessagingTimeout(field, seconds: budget.elementTimeout)
        guard fieldRoles.contains(reader.role(field) ?? "") else { return nil }
        return reader.value(field)
    }

    // MARK: Walk

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

    /// The value of the one control whose value is among the labels; nil for none, for several, and for
    /// a walk the budget cut short or a list that did not answer, where a second match may lie beyond what
    /// was read.
    static func controlValue<Reader: AccessibilityTreeReading>(
        matchingAny labels: Set<String>,
        in roots: [Reader.Node],
        reader  : Reader,
        budget  : WalkBudget = .standard,
        timeout : (Reader.Node) -> Void = { _ in }
    ) -> String? {
        var matches: [String] = []
        let complete = walk(roots, reader: reader, budget: budget, timeout: timeout) { node in
            guard controlRoles.contains(reader.role(node) ?? ""), let value = reader.value(node) else { return false }
            if labels.contains(LabelText.normalize(value)) { matches.append(value) }
            return false
        }
        return complete && matches.count == 1 ? matches[0] : nil
    }

    /// The state of the one checkbox or radio button titled or described `want` (normalized); nil for
    /// none, for several, for one whose value is no state, and for a walk the budget cut short or a list
    /// that did not answer.
    static func toggleState<Reader: AccessibilityTreeReading>(
        labelled want: String,
        in roots     : [Reader.Node],
        reader       : Reader,
        budget       : WalkBudget,
        timeout      : (Reader.Node) -> Void = { _ in }
    ) -> ControlState? {
        var states: [ControlState?] = []
        let complete = walk(roots, reader: reader, budget: budget, timeout: timeout) { node in
            guard toggleRoles.contains(reader.role(node) ?? ""),
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

    /// Visits the nodes under the roots depth first until `visit` returns true or the budget runs
    /// out: `budget.elements` nodes, `budget.depth` levels, `budget.deadline` of wall time. `timeout`
    /// is given each node before it is read. Answers false when the element count or the deadline cut
    /// the walk short, or a node's children did not answer (`readChildren`, M2): the walk goes on with
    /// the siblings it can read, but what it saw is not the whole tree. Levels below `budget.depth` are
    /// outside every walk and never count as cut. `firstControl` ignores the answer: it presses the first
    /// match, which never claimed to be the only one.
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
        clock  : ContinuousClock = ContinuousClock(),
        timeout: (Reader.Node) -> Void = { _ in },
        visit  : (Reader.Node) -> Bool
    ) -> Bool {
        let end = clock.now.advanced(by: budget.deadline)
        var visited = 0
        var stop = false
        var exhausted = false
        var unlisted = false
        func descend(_ node: Reader.Node, _ depth: Int) {
            guard !stop, depth <= budget.depth else { return }
            guard visited < budget.elements, clock.now < end else { stop = true; exhausted = true; return }
            visited += 1
            timeout(node)
            if visit(node) { stop = true; return }
            guard let children = reader.readChildren(node) else { unlisted = true; return }
            for child in children { descend(child, depth + 1) }
        }
        for root in roots { descend(root, 0) }
        return !exhausted && !unlisted
    }
}
