import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import AccessibilityActions

/// The controller's walks on built trees: each stays inside its budget whatever the tree's size, and a
/// walk the budget stopped answers incomplete, as one that met unread children does.
@Suite("Accessibility controller walk budget")
struct AccessibilityControllerWalkTests {

    @Test("A walk visits at most the budget's elements and then answers incomplete")
    func elementBudget() {
        let budget = budget(elements: 50)
        var visited = 0
        let complete = AccessibilityController.walk([wide(100)], reader: WalkReader(), budget: budget) { _ in
            visited += 1
            return false
        }
        #expect(visited == 50)
        #expect(!complete)
        #expect(AccessibilityController.firstControl(in: [wide(100)], reader: WalkReader(), budget: budget) { _ in true } == nil)
        #expect(AccessibilityController.firstControl(in: [wide(10)], reader: WalkReader(), budget: budget) { _ in true } != nil)
    }

    @Test("A tree that fits the budget is complete")
    func fitsBudget() {
        let complete = AccessibilityController.walk([wide(10)], reader: WalkReader(), budget: budget(elements: 12)) { _ in
            false
        }
        #expect(complete)
    }

    @Test("A walk past its deadline visits nothing and answers incomplete")
    func deadline() {
        var visited = 0
        let complete = AccessibilityController.walk([wide(10)], reader: WalkReader(), budget: budget(deadline: .zero)) { _ in
            visited += 1
            return false
        }
        #expect(visited == 0)
        #expect(!complete)
    }

    @Test("A control below the depth limit is not reached")
    func depth() {
        var deep = WalkNode("AXPopUpButton", value: "Medio")
        for _ in 0..<20 { deep = WalkNode("AXGroup", children: [deep]) }
        #expect(AccessibilityController.firstControl(in: [deep], reader: WalkReader()) { _ in true } == nil)
    }

    @Test("Every visited element gets its messaging timeout before it is read")
    func timeoutOnEveryElement() {
        var timed = 0
        var visited = 0
        AccessibilityController.walk([wide(10)], reader: WalkReader(), timeout: { _ in timed += 1 }) { _ in
            visited += 1
            return false
        }
        #expect(timed == visited && visited == 12)
    }

    @Test("The standard budget leaves room for a dense mixer")
    func standardBudget() {
        #expect(AccessibilityController.WalkBudget.standard.elements >= 4_000)
        #expect(AccessibilityController.WalkBudget.standard.deadline >= .seconds(3))
        #expect(AccessibilityController.WalkBudget.standard.depth == 10)
    }

    /// A window holding `count` groups, with a pop-up showing "Medio" after them.
    private func wide(_ count: Int) -> WalkNode {
        WalkNode("AXWindow", children: (0..<count).map { _ in WalkNode("AXGroup") } + [
            WalkNode("AXPopUpButton", value: "Medio")
        ])
    }

    private func budget(
        elements: Int      = 4_000,
        deadline: Duration = .seconds(3)
    ) -> AccessibilityController.WalkBudget {
        AccessibilityController.WalkBudget(
            elements          : elements,
            depth             : 10,
            deadline          : deadline,
            applicationTimeout: 1,
            elementTimeout    : 0.25
        )
    }
}

final class WalkNode: @unchecked Sendable {
    let role: String
    let value: String?
    let actions: [String]
    let children: [WalkNode]

    init(_ role: String, value: String? = nil, actions: [String] = [kAXPressAction], children: [WalkNode] = []) {
        self.role     = role
        self.value    = value
        self.actions  = actions
        self.children = children
    }
}

struct WalkReader: AccessibilityTreeReading {
    func isSameNode(_ first: WalkNode, _ second: WalkNode) -> Bool { first === second }
    func role(_ node: WalkNode) -> String? { node.role }
    func subrole(_ node: WalkNode) -> String? { nil }
    func title(_ node: WalkNode) -> String? { nil }
    func descriptionText(_ node: WalkNode) -> String? { nil }
    func identifier(_ node: WalkNode) -> String? { nil }
    func value(_ node: WalkNode) -> String? { node.value }
    func numericValue(_ node: WalkNode) -> Int? { nil }
    func isEnabled(_ node: WalkNode) -> Bool? { true }
    func actions(_ node: WalkNode) -> [String] { node.actions }
    func frame(_ node: WalkNode) -> CGRect? { nil }
    func children(_ node: WalkNode) -> [WalkNode] { node.children }
}
