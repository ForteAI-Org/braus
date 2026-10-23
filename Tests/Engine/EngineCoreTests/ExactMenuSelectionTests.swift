import CoreGraphics
import EngineCore
import PerceptionCore
import Testing

@Suite("Exact dropdown semantics preserve complete duration labels")
struct ExactMenuSelectionTests {

    @Test("duration, dot, triplet and musical distinctions are never dropped")
    func completeTitles() {
        let titles = ["J 1/8 note", "v J 1/8 note", "1/8 note.", "1/8 note triplet", "♪", "♩"]
        #expect(LabelText.exactMenuItemMatch("1/4 note", in: titles) == nil)
        #expect(LabelText.exactMenuItemMatch("1/8 note", in: titles) == nil)
        #expect(LabelText.exactMenuItemMatch("1/8 note.", in: titles) == 2)
        #expect(LabelText.exactMenuItemMatch("J 1/8 note", in: titles) == 0)
        #expect(LabelText.exactMenuItemMatch("v J 1/8 note", in: titles) == 1)
        #expect(LabelText.exactMenuItemMatch("♪", in: titles) == 4)
        #expect(LabelText.exactMenuItemMatch("♩", in: titles) == 5)
        #expect(LabelText.exactMenuItemMatch("1/8 note", in: ["1/8 note", "1/8 note."]) == 0)
    }

    @Test("normalization preserves typography contracts but refuses collisions")
    func titleNormalization() {
        #expect(LabelText.exactMenuItemMatch("save as...", in: ["Save As…"]) == 0)
        #expect(LabelText.exactMenuItemMatch("save as", in: ["Save As…", "Save As..."]) == nil)
        #expect(LabelText.exactMenuItemMatch("", in: [""]) == nil)
    }

    @Test("native keyboard plans require unique complete current and target rows")
    func keyboardRows() throws {
        let rows = [PopupRow(title: "1/8 note", order: 0), PopupRow(title: "1/8 note.", order: 1),
                    PopupRow(title: "1/8 note triplet", order: 2)]
        let plan = try #require(PopupRowPick.plan(rows: rows, currentValue: "1/8 note", target: "1/8 note.", exactTitleOnly: true))
        #expect(plan.currentIndex == 0 && plan.targetIndex == 1 && plan.delta == 1)
        #expect(PopupRowPick.plan(rows: rows, currentValue: "1/4 note", target: "1/8 note.", exactTitleOnly: true) == nil)
        var disabled = rows
        disabled[1].isEnabled = false
        #expect(PopupRowPick.plan(rows: disabled, currentValue: "1/8 note", target: "1/8 note.", exactTitleOnly: true) == nil)
        let repeated = rows + [rows[0]]
        #expect(PopupRowPick.plan(rows: repeated, currentValue: "1/8 note", target: "1/8 note.", exactTitleOnly: true) == nil)
        #expect(PopupRowPick.plan(rows: repeated, currentValue: "1/8 note.", target: "1/8 note", exactTitleOnly: true) == nil)
    }

    @Test("pixel keyboard plans preserve the current row's duration distinction")
    func pixelRows() throws {
        let plain = SceneElement(id: "plain", kind: .text, label: "1/8 note", bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05))
        let dotted = SceneElement(id: "dotted", kind: .text, label: "1/8 note.", bounds: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.05))
        let plan = try #require(PopupRowPick.plan(rows: [[plain], [dotted]], currentValue: "1/8 note.", target: plain, exactTitleOnly: true))
        #expect(plan.currentIndex == 1 && plan.targetIndex == 0 && plan.delta == -1)
        var disabled = dotted
        disabled.id = "disabled-middle"
        disabled.label = "Disabled row"
        disabled.isEnabled = false
        #expect(PopupRowPick.plan(rows: [[plain], [disabled], [dotted]], currentValue: "1/8 note", target: dotted, exactTitleOnly: true) == nil)
    }

    @Test("readback cannot verify another duration just because punctuation normalizes away")
    func readback() {
        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let control = SceneElement(id: "duration", kind: .control, label: "Duration", bounds: bounds,
                                   role: "AXPopUpButton", value: "1/8 note")
        var after = control
        after.value = "1/8 note."
        #expect(!DropdownValueVerification.verifies(item: "1/8 note", control: control, after: [after], exactTitleOnly: true))
        #expect(DropdownValueVerification.verifies(item: "1/8 note.", control: control, after: [after], exactTitleOnly: true))
        after.bounds.y = 0.8
        #expect(!DropdownValueVerification.verifies(item: "1/8 note.", control: control, after: [after], exactTitleOnly: true))
    }
    @Test("native contradiction and overlapping controls cannot be overridden by a matching pixel label")
    func contradictoryReadback() {
        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let control = SceneElement(id: "duration", kind: .control, label: "Duration", bounds: bounds,
                                   role: "AXPopUpButton", value: "1/8 note")
        var native = control
        native.value = "1/8 note."
        let pixels = SceneElement(id: "pixels", kind: .text, label: "1/8 note", bounds: bounds)
        #expect(!DropdownValueVerification.verifies(item: "1/8 note", control: control, after: [native, pixels], exactTitleOnly: true))
        #expect(!DropdownValueVerification.verifies(item: "1/8 note", control: control, after: [control, native], exactTitleOnly: true))
        #expect(DropdownValueVerification.verifies(item: "1/8 note", control: control, after: [pixels], exactTitleOnly: true))
        #expect(!DropdownValueVerification.verifies(item: "1/8 note", control: control, after: [pixels, pixels], exactTitleOnly: true))
    }

}
