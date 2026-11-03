import Foundation
import PerceptionCore
import Testing

struct SceneTextAdapterTests {
    @Test @MainActor
    func adapterUsesSafeCutsAndIsolatesKnowledge() async throws {
        let field = SceneElement(
            id: "field", kind: .control, label: "Folder A",
            bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03),
            role: "AXTextField", value: "abcdef", selectedRange: NSRange(location: 3, length: 0)
        )
        let scene = SceneSnapshot(
            bundleID: "com.example.app", appName: "Example", windowTitle: "Folder A",
            viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: [field],
            knowledge: SceneKnowledge(status: .applied, window: ["Folder B"])
        )
        let rendered = try await SceneTextUnderTest.render(scene)
        #expect(rendered.text == scene.text(cuts: .safe))
        #expect(!rendered.text.contains("[sel"))
        #expect(rendered.brainParts == ["memory: what was learned in this window's state is shown\n  window: Folder B\n"])
        #expect(rendered.kind == nil)
    }
}
