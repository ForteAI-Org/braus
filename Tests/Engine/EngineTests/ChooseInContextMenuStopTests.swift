import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

struct ChooseInContextMenuStopTests {
    @Test
    func stopAfterRightClickPreventsFurtherInput() async {
        let wait = InterruptibleWait()
        let actuator = UncertainDeliveryTests.StoppingActuator(wait, fails: false)
        let element = SceneElement(id: "control|target", kind: .control, label: "Target",
            bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1), role: "AXButton")
        let window = PerceivedWindow(scene: SceneSnapshot(bundleID: "com.x", appName: "X",
            windowTitle: "Before", viewportPixelSize: ViewportPixelSize(width: 800, height: 600),
            elements: [element]), frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let engine = ActionEngine(.init(scenes: ActionEngineTests.ScriptedScenes([window]), actuator: actuator,
            windows: ActionEngineTests.ScriptedWindows([[]])), pause: { _ in })
        await InterruptibleWait.$current.withValue(wait) {
            let result = await engine.deliver(InputRequest(processID: 42, bundleID: "com.x", appName: "X",
                input: .contextMenu(on: "Target", item: "Copy")))
            #expect(actuator.calls == 1)
            #expect(result.scene == nil)
            #expect(!Task.isCancelled)
        }
    }
}
