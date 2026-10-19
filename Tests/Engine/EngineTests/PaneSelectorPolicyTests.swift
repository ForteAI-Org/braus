import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// B2 trial on Numbers (17/10/2026): the inspector's "Format" pane selector, an `AXRadioButton` beside "Organise", was
/// refused as destructive by the substring "format". A pane selector named exactly Format is clicked; a Format
/// button, a Format menu item, an element with no role and every other destructive label are still refused.
@Suite("The destructive policy and a pane selector (B2)")
struct PaneSelectorPolicyTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows

    private let pid: pid_t = 4242
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Vendite", number: 1)

    private func click(_ label: String, role: String?) async -> (ActOutcome, RecordingActuator) {
        let control = SceneElement(id: "control|\(label)", kind: .control, label: label,
                                   bounds: NormalizedRect(x: 0.913, y: 0.033, width: 0.033, height: 0.04), role: role,
                                   state: role == "AXRadioButton" ? .off : nil)
        let scene = PerceivedWindow(scene: SceneSnapshot(bundleID: "com.apple.Numbers", appName: "Numbers", windowTitle: "Vendite",
                                                         viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
                                                         elements: [control]),
                                    frame: CGRect(x: 100, y: 100, width: 1000, height: 800))
        let actuator = RecordingActuator()
        let engine = ActionEngine(ActionEngine.Dependencies(scenes: ScriptedScenes([scene, scene]), actuator: actuator,
                                                            windows: ScriptedWindows([[mainWindow]])), pause: { _ in })
        let outcome = await engine.act(ActionRequest(processID: pid, bundleID: "com.apple.Numbers", appName: "Numbers",
                                                     target: label, verb: .click))
        return (outcome, actuator)
    }

    @Test("the Format pane selector is clicked, not refused")
    func paneSelectorIsClicked() async {
        let (outcome, actuator) = await click("Format", role: "AXRadioButton")
        #expect(outcome.kind != .refused, Comment(rawValue: outcome.message))
        #expect(actuator.gestures.count == 1, "one click went out")
    }

    @Test("a Format button, a Format menu item, a Format with no role, or a Delete radio button is refused with nothing sent",
          arguments: [("Format", "AXButton"), ("Format\u{2026}", "AXMenuItem"), ("Format", nil), ("Delete", "AXRadioButton")]
            as [(String, String?)])
    func destructiveIsRefused(label: String, role: String?) async {
        let (outcome, actuator) = await click(label, role: role)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty, "nothing was sent")
    }
}
