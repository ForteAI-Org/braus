import CoreGraphics
import EngineCore
@testable import Engine
import Foundation
import PerceptionCore
import Testing

@Suite("Gesture evidence")
struct GestureEvidenceTests {
    static func element(_ id: String = "display", value: String = "12", container: String? = nil) -> SceneElement {
        SceneElement(id: id, kind: .text, label: value,
            bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
            role: "AXStaticText", value: value, container: container)
    }

    static func window(_ elements: [SceneElement], quality: CaptureQuality = .unknown) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "Window",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: elements),
            frame: .zero, capture: quality)
    }

    @Test func allChangesAndPrivateSubjects() {
        let first = Self.element("first", container: "Report.docx")
        let second = Self.element("second", container: "Report.docx")
        let after = [Self.element("first", value: "123", container: "Report.docx"),
                     Self.element("second", value: "456", container: "Report.docx")]
        let evidence = SceneEvidence.observe(before: Self.window([first, second]), after: Self.window(after),
                                             target: nil, learnableEffect: nil)
        #expect(evidence.changes.map(\.kind) == [.nativeText, .nativeText])
        #expect(evidence.changes.map(\.stability) == [.instanceValue, .instanceValue])
        #expect(evidence.changes.map(\.subject) == ["text.AXStaticText@c1#1", "text.AXStaticText@c1#2"])
        #expect(evidence.learnableEffect == nil && evidence.verdictEffect == nil)
        #expect(SubjectKey.of(first, in: Self.window([first, second]).scene, target: nil)
            == SubjectKey.of(after[0], in: Self.window(after).scene, target: nil))
        let root = SceneEvidence.observe(before: Self.window([Self.element()]),
            after: Self.window([Self.element(value: "123")]), target: nil, learnableEffect: nil)
        #expect(root.changes.first?.subject == "text.AXStaticText@root#1")
    }

    @Test func targetAndContainerKeys() {
        var toolbar = Self.element("toolbar", container: "Toolbar")
        toolbar.kind = .control
        toolbar.role = "AXButton"
        var field = Self.element("field", value: "secret", container: "Report.docx")
        field.kind = .control
        field.role = "AXTextField"
        let scene = Self.window([toolbar, field]).scene
        #expect(SubjectKey.of(field, in: scene, target: field) == "control.AXTextField@c2#t")
    }

    @Test func titleDoesNotHideOtherChanges() {
        var off = Self.element("toggle", value: "Option")
        off.kind = .control
        off.state = .off
        var on = off
        on.state = .on
        let before = Self.window([off, Self.element()])
        var afterScene = Self.window([on, Self.element(value: "123")]).scene
        afterScene.windowTitle = "Other Window"
        let after = PerceivedWindow(scene: afterScene, frame: .zero)
        let effect = SceneEffect.windowTitleChanged(title: "Other Window")
        let evidence = SceneEvidence.observe(before: before, after: after, target: off, learnableEffect: effect)
        #expect(evidence.changes.map(\.kind) == [.structural, .state, .nativeText])
        #expect(evidence.verdictEffect?.family == "windowTitleChanged")
    }

    @Test func recognizedTextIsUnreliable() {
        var old = Self.element(value: "Before")
        old.role = nil
        old.value = nil
        var new = old
        new.label = "After"
        let evidence = SceneEvidence.observe(before: Self.window([old]), after: Self.window([new]),
                                             target: nil, learnableEffect: nil)
        #expect(evidence.changes.count == 1)
        #expect(evidence.changes.first?.kind == .recognizedText)
        #expect(evidence.changes.first?.stability == .unreliable)
    }
}

@Suite("Capture quality evidence")
struct CaptureQualityEvidenceTests {
    @Test func quality() {
        let qualities: [CaptureQuality] = [
            CaptureQuality(walkCompleted: true, windowFound: true),
            CaptureQuality(walkCompleted: false, windowFound: true),
            CaptureQuality(windowFound: false),
            CaptureQuality(walkCompleted: true, stoppedBy: .deadline, windowFound: true), .unknown
        ]
        for (index, quality) in qualities.enumerated() {
            for reverse in [false, true] {
                let plain = GestureEvidenceTests.window([GestureEvidenceTests.element()])
                let limited = GestureEvidenceTests.window([GestureEvidenceTests.element()], quality: quality)
                let before = reverse ? limited : plain, after = reverse ? plain : limited
                let evidence = ActionEngine.evidence(before: before, after: after, targetID: "",
                                                       popupIsOpen: false)
                #expect(evidence.comparable == (index == 0 || index == 4))
                #expect(evidence.changes.isEmpty && evidence.learnableEffect == nil)
                #expect(ActVerification.verdict(before: before, after: after, effect: evidence.learnableEffect)
                    == (evidence.comparable ? .ghost : .unattributable))
            }
        }
    }
}
