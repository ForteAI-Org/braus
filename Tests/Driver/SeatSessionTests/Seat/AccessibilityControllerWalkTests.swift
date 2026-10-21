import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import AccessibilityActions

/// The controller's walks on built trees: each stays inside its budget, whatever the app's size, so a
/// dense app answers in time with a partial answer (MacDriver spec section 3, rule 3; #47).
@Suite("Accessibility controller walk budget")
struct AccessibilityControllerWalkTests {

    final class Node: @unchecked Sendable {
        let role: String
        let value: String?
        let title: String?
        let number: Int?
        let children: [Node]
        /// The children did not answer: `children` reads empty, as the live reader's does.
        let unreadable: Bool
        init(_ role: String, value: String? = nil, title: String? = nil, number: Int? = nil, unreadable: Bool = false,
             children: [Node] = []) {
            self.role = role
            self.value = value
            self.title = title
            self.number = number
            self.unreadable = unreadable
            self.children = children
        }
    }

    struct Reader: AccessibilityTreeReading {
        func role(_ node: Node) -> String? { node.role }
        func subrole(_ node: Node) -> String? { nil }
        func title(_ node: Node) -> String? { node.title }
        func descriptionText(_ node: Node) -> String? { nil }
        func identifier(_ node: Node) -> String? { nil }
        func value(_ node: Node) -> String? { node.value }
        func numericValue(_ node: Node) -> Int? { node.number }
        func isEnabled(_ node: Node) -> Bool? { true }
        func actions(_ node: Node) -> [String] { [] }
        func frame(_ node: Node) -> CGRect? { nil }
        func children(_ node: Node) -> [Node] { node.unreadable ? [] : node.children }
        func readChildren(_ node: Node) -> [Node]? { node.unreadable ? nil : node.children }
    }

    /// A reader that cannot tell an unread list from a leaf: it answers `children` only.
    struct PlainReader: AccessibilityTreeReading {
        func role(_ node: Node) -> String? { node.role }
        func subrole(_ node: Node) -> String? { nil }
        func title(_ node: Node) -> String? { node.title }
        func descriptionText(_ node: Node) -> String? { nil }
        func identifier(_ node: Node) -> String? { nil }
        func value(_ node: Node) -> String? { node.value }
        func numericValue(_ node: Node) -> Int? { node.number }
        func isEnabled(_ node: Node) -> Bool? { true }
        func actions(_ node: Node) -> [String] { [] }
        func frame(_ node: Node) -> CGRect? { nil }
        func children(_ node: Node) -> [Node] { node.unreadable ? [] : node.children }
    }

    /// A pop-up showing "Medio" and a box "Muto" on, then a group whose children did not answer and may
    /// hold another of each; `unreadable` false lists them.
    private func duplicates(unreadable: Bool) -> Node {
        Node("AXWindow", children: [
            Node("AXPopUpButton", value: "Medio"), Node("AXCheckBox", title: "Muto", number: 1),
            Node("AXGroup", unreadable: unreadable, children: [Node("AXPopUpButton", value: "Medio"),
                                                              Node("AXCheckBox", title: "Muto", number: 0)]),
        ])
    }

    @Test("M2: a candidate found before a branch that did not list its children is not the only one: no value, no state, an incomplete walk")
    func candidateBeforeUnreadable() {
        let root = duplicates(unreadable: true)
        #expect(AccessibilityController.controlValue(matchingAny: ["medio"], in: [root], reader: Reader(), budget: .standard) == nil)
        #expect(AccessibilityController.toggleState(labelled: "muto", in: [root], reader: Reader(), budget: .standard) == nil)
        #expect(!AccessibilityController.walk([root], reader: Reader(), budget: .standard) { _ in false })
    }

    @Test("M2 positive controls: an empty leaf is a complete walk that answers the one value and state; the duplicates read in full are two")
    func completeControls() {
        let root = Node("AXWindow", children: [Node("AXPopUpButton", value: "Medio"), Node("AXCheckBox", title: "Muto", number: 1),
                                               Node("AXGroup", children: [])])
        #expect(AccessibilityController.walk([root], reader: Reader(), budget: .standard) { _ in false })
        #expect(AccessibilityController.controlValue(matchingAny: ["medio"], in: [root], reader: Reader(), budget: .standard) == "Medio")
        #expect(AccessibilityController.toggleState(labelled: "muto", in: [root], reader: Reader(), budget: .standard) == .on)
        let listed = duplicates(unreadable: false)
        #expect(AccessibilityController.controlValue(matchingAny: ["medio"], in: [listed], reader: Reader(), budget: .standard) == nil)
    }

    @Test("M2: a reader that answers only children walks as before: what it lists is all there is")
    func readerWithoutReadChildren() {
        #expect(AccessibilityController.walk([duplicates(unreadable: true)], reader: PlainReader(), budget: .standard) { _ in false })
        #expect(AccessibilityController.controlValue(matchingAny: ["medio"], in: [duplicates(unreadable: true)],
                                                     reader: PlainReader(), budget: .standard) == "Medio")
    }

    /// A window holding `count` groups, with a pop-up showing "Medio" after them.
    private func wide(_ count: Int) -> Node {
        Node("AXWindow", children: (0..<count).map { _ in Node("AXGroup") } + [Node("AXPopUpButton", value: "Medio")])
    }

    @Test("A walk visits at most the budget's elements, and a control past them is not found")
    func elementBudget() {
        var visited = 0
        AccessibilityController.walk([wide(5_000)], reader: Reader(), budget: .standard) { _ in
            visited += 1
            return false
        }
        #expect(visited == AccessibilityController.WalkBudget.standard.elements)
        #expect(AccessibilityController.firstControl(in: [wide(5_000)], reader: Reader(), budget: .standard) { _ in true } == nil)
        #expect(AccessibilityController.firstControl(in: [wide(10)], reader: Reader(), budget: .standard) { _ in true } != nil)
    }

    @Test("A walk stops at the depth limit and at the deadline")
    func depthAndDeadline() {
        var deep = Node("AXPopUpButton", value: "Medio")
        for _ in 0..<20 { deep = Node("AXGroup", children: [deep]) }
        #expect(AccessibilityController.firstControl(in: [deep], reader: Reader(), budget: .standard) { _ in true } == nil)
        var visited = 0
        AccessibilityController.walk([wide(10)], reader: Reader(), budget: .init(deadline: .zero)) { _ in
            visited += 1
            return false
        }
        #expect(visited == 0)
    }

    @Test("Every visited element gets its messaging timeout before it is read")
    func timeoutOnEveryElement() {
        var timed = 0
        var visited = 0
        AccessibilityController.walk([wide(10)], reader: Reader(), budget: .standard, timeout: { _ in timed += 1 }) { _ in
            visited += 1
            return false
        }
        #expect(timed == visited && visited == 12)
    }

    @Test("A control's value among the labels, only when one control has it")
    func controlValue() {
        let window = Node("AXWindow", children: [
            Node("AXPopUpButton", value: "Medio"), Node("AXComboBox", value: "Doppio"), Node("AXPopUpButton", value: "Doppio"),
        ])
        #expect(AccessibilityController.controlValue(matchingAny: ["medio"], in: [window], reader: Reader(), budget: .standard) == "Medio")
        #expect(AccessibilityController.controlValue(matchingAny: ["doppio"], in: [window], reader: Reader(), budget: .standard) == nil)
    }

    @Test("A walk the budget cut short says so; one that covered the tree, or stopped at a match, does not")
    func walkReportsTheCut() {
        #expect(!AccessibilityController.walk([wide(5_000)], reader: Reader(), budget: .standard) { _ in false })
        #expect(AccessibilityController.walk([wide(10)], reader: Reader(), budget: .standard) { _ in false })
        #expect(AccessibilityController.walk([wide(5_000)], reader: Reader(), budget: .standard) { _ in true })
    }

    @Test("A value found once in a walk the budget cut short is unknown: a second may lie past the cut")
    func controlValuePastTheCut() {
        let window = Node("AXWindow", children: [Node("AXPopUpButton", value: "Medio")]
            + (0..<5_000).map { _ in Node("AXGroup") } + [Node("AXPopUpButton", value: "Medio")])
        #expect(AccessibilityController.controlValue(matchingAny: ["medio"], in: [window], reader: Reader(), budget: .standard) == nil)
    }

    @Test("A toggle's state by its title, only for one toggle so named in a walk that covered the tree")
    func toggleStateByLabel() {
        let window = Node("AXWindow", children: [
            Node("AXCheckBox", title: "Loop", number: 1), Node("AXRadioButton", title: "Doppio", number: 0),
            Node("AXCheckBox", title: "Doppio", number: 1), Node("AXButton", title: "Solo", number: 1),
        ])
        #expect(AccessibilityController.toggleState(labelled: "loop", in: [window], reader: Reader(), budget: .standard) == .on)
        #expect(AccessibilityController.toggleState(labelled: "doppio", in: [window], reader: Reader(), budget: .standard) == nil)
        #expect(AccessibilityController.toggleState(labelled: "solo", in: [window], reader: Reader(), budget: .standard) == nil)
        let cut = Node("AXWindow", children: [Node("AXCheckBox", title: "Loop", number: 1)]
            + (0..<5_000).map { _ in Node("AXGroup") })
        #expect(AccessibilityController.toggleState(labelled: "loop", in: [cut], reader: Reader(), budget: .standard) == nil)
    }
}
