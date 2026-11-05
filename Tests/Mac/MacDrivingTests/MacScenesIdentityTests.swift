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

    // MARK: The system's window sharing indicator

    /// The window macOS adds to an application while one of its windows is captured, measured on 03/11/2026.
    static let indicator = MacTreeNode(role: "AXWindow", subrole: "AXDialog", title: "Window",
                                       frame: CGRect(x: 0, y: 0, width: 66, height: 20), children: [
        MacTreeNode(role: "AXButton", title: "WindowSharingSessionButton", actions: ["AXPress"]),
    ])

    static func scenes(_ windows: [(summary: MacWindowSummary, tree: MacTreeNode)]) -> MacScenes {
        MacScenes(reader: FakeTreeReader(windows: [9: windows]), serverWindows: { _ in [] },
                  identity: { _ in ("com.example.notes", "Notes") })
    }

    @Test("the indicator in front, even focused, is passed over for the application's window")
    func theIndicatorIsNoWindowOfTheApplication() async throws {
        let first = MacWindowSummary(index: 0, role: "AXWindow", subrole: "AXDialog", title: "Window", isFocused: true)
        let document = MacWindowSummary(index: 1, role: "AXWindow", subrole: "AXStandardWindow", frame: Self.frame)
        let scene = try await Self.scenes([(first, Self.indicator), (document, Self.window)]).scene(of: 9)
        #expect(scene.perceived.scene.windowTitle == "Notes")
        #expect(scene.perceived.surface != .dialog)
        await #expect(throws: MacTreeFailure.windowNotFound(index: 0)) {
            _ = try await Self.scenes([(first, Self.indicator)]).scene(of: 9)
        }
    }

    @Test("a real dialog with one button of its own stays the window read, and a dialog")
    func aDialogIsStillRead() async throws {
        let alert = MacTreeNode(role: "AXWindow", subrole: "AXDialog", title: "Alert", frame: Self.frame, children: [
            MacTreeNode(role: "AXButton", title: "OK", actions: ["AXPress"]),
        ])
        let summary = MacWindowSummary(index: 0, role: "AXWindow", subrole: "AXDialog", title: "Alert", isFocused: true)
        let scene = try await Self.scenes([(summary, alert)]).scene(of: 9)
        #expect(scene.perceived.scene.windowTitle == "Alert")
        #expect(scene.perceived.surface == .dialog)
    }
}
