import CoreGraphics
import EngineCore
import Foundation
import MacDriver
import MacDriving
import PerceptionCore
import Testing

/// The scene's bundle identifier and app name come from `MacScenes.identity`: the workspace's answer for a live
/// process by default, which knows no application behind a process that is not one, or what a fake process is
/// declared to be, so a test's scenes can be recorded under an app (M05, the rung on the record).
@Suite("MacScenes: who the process is")
struct MacScenesIdentityTests {

    static let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let window = MacTreeNode(role: "AXWindow", title: "Notes", frame: frame, children: [
        MacTreeNode(role: "AXButton", title: "Save", frame: CGRect(x: 0, y: 0, width: 200, height: 200), actions: ["AXPress"]),
    ])

    private func reader() -> FakeTreeReader {
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: Self.frame, isFocused: true)
        return FakeTreeReader(windows: [9: [(summary, Self.window)]])
    }

    @Test("an identity given is the scene's; the default is the workspace's answer, empty for a process that is no application")
    func identityIsTheScenes() async throws {
        let declared = MacScenes(reader: reader(), serverWindows: { _ in [] }, identity: { pid in ("com.example.notes", "Notes \(pid)") })
        let scene = try await declared.scene(of: 9)
        #expect(scene.perceived.scene.bundleID == "com.example.notes" && scene.perceived.scene.appName == "Notes 9")
        let live = MacScenes(reader: reader(), serverWindows: { _ in [] })
        let unknown = try await live.scene(of: 9)
        #expect(unknown.perceived.scene.bundleID.isEmpty && unknown.perceived.scene.appName.isEmpty,
                "pid 9 is no application the workspace knows: \(unknown.perceived.scene.bundleID)")
    }
}
