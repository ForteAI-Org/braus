import Foundation
@testable import PerceptionCore
import Testing

struct SceneTextCutsTests {
    private func icon(_ id: String, _ y: Double) -> SceneElement {
        SceneElement(id: id, kind: .icon, label: "(unlabeled)",
                     bounds: NormalizedRect(x: 0.1, y: y, width: 0.02, height: 0.02), isUnlabeled: true)
    }

    private func scene(_ elements: [SceneElement]) -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.example.app", appName: "Example", windowTitle: "Folder A",
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
    }

    @Test
    func sharedIDsOnlyDisappearWhenAmbiguous() {
        let first = icon("shared", 0.1)
        let second = icon("shared", 0.5)
        let own = icon("own", 0.8)
        let value = scene([first, second, own])
        #expect(value.resolve(target: "shared") == .ambiguous(2))
        #expect(value.text(cuts: .safe) == "Example (com.example.app) \"Folder A\" 1000x800, 3 elements\nicons: own@10,80\n")
        #expect(scene([first, second]).text(cuts: .safe).contains("icons:") == false)
        #expect(value.text(cuts: []) == "Example (com.example.app) \"Folder A\" 1000x800, 3 elements\nicons: shared×2 own@10,80\n")
        #expect(value.text() == value.text(cuts: []))
        #expect(value.text(cuts: .emptySelections) == value.text())

        let overlap = icon("shared", 0.101)
        let collapsed = scene([first, overlap])
        #expect(collapsed.resolve(target: "shared") == .found(first))
        #expect(collapsed.text(cuts: .safe) == collapsed.text())
        #expect(collapsed.text(cuts: .safe).contains("shared×2"))
        #expect(collapsed.resolve(target: "shared") == .found(first))

        let middle = icon("shared", 0.105)
        let sourceOrder = scene([middle, icon("shared", 0.1), icon("shared", 0.11)])
        #expect(sourceOrder.resolve(target: "shared") == .found(middle))
        #expect(sourceOrder.text(cuts: .safe) == sourceOrder.text())
    }

    @Test
    func emptySelectionsAndProtectedLabels() {
        var field = SceneElement(id: "field", kind: .control, label: "Folder A",
                                 bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03),
                                 role: "AXTextField", value: "abcdef", selectedRange: NSRange(location: 3, length: 0))
        let label = SceneElement(id: "heading", kind: .text, label: "## Folder A\nFolder B", bounds: field.bounds)
        let value = scene([field, label])
        #expect(value.text() == "Example (com.example.app) \"Folder A\" 1000x800, 2 elements\n"
            + "[field] Folder A id:'field' = abcdef [sel 3..3/6] @10,20\n"
            + "[text] ## Folder A Folder B @10,20\n")
        #expect(!value.text(cuts: .safe).contains("[sel"))
        #expect(value.text(cuts: .sharedIconIDs) == value.text())
        #expect(value.text(cuts: .safe).contains("[text] ## Folder A Folder B @10,20\n"))
        #expect(value.resolve(target: "## Folder A Folder B") == .found(label))
        field.selectedRange = NSRange(location: 2, length: 3)
        #expect(scene([field]).text(cuts: .safe).contains("[sel 2..5/6]"))
    }

    @Test
    func caretMoveIsNoChangeInV2() {
        var field = SceneElement(id: "field", kind: .control, label: "Folder A",
                                 bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03),
                                 role: "AXTextField", value: "abcdef", selectedRange: NSRange(location: 3, length: 0))
        let before = scene([field])
        field.selectedRange = NSRange(location: 4, length: 0)
        let after = scene([field])
        let original = SceneChanges.text(from: before, to: after, since: 1)
        #expect(original.contains("[sel 4..4/6]"))
        #expect(original.contains("selection 3..3"))
        #expect(original == SceneChanges.text(from: before, to: after, since: 1, cuts: []))
        #expect(SceneChanges.elements(from: before, to: after).count == 1)
        #expect(SceneChanges.text(from: before, to: after, since: 1, cuts: .safe) == "Unchanged since revision 1.")
        field.selectedRange = NSRange(location: 2, length: 3)
        let selected = scene([field])
        let changed = SceneChanges.text(from: after, to: selected, since: 2, cuts: .safe)
        #expect(changed.contains("[sel 2..5/6]"))
        #expect(changed.contains("no selection"))
        #expect(SceneChanges.text(from: selected, to: after, since: 3, cuts: .safe).contains("selection 2..5"))
        #expect(!SceneChanges.text(from: scene([]), to: after, since: 1, cuts: .safe).contains("[sel"))
    }
}


extension SceneTextCutsTests {
    @Test
    func sharedIDsKeepTargetsAcrossSections() {
        var middle = icon("shared", 0.105)
        middle.section = "Folder A"
        var first = icon("shared", 0.1)
        first.section = "Folder B"
        var last = icon("shared", 0.11)
        last.section = "Folder B"
        var value = scene([middle, first, last])
        value.sections = ["Folder A", "Folder B"].map {
            SceneSection(name: $0, bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(value.resolve(target: "shared") == .found(middle))
        #expect(value.text(cuts: .safe) == value.text())
    }
}
