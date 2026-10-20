import CoreGraphics
import EngineCore
import Foundation
import MacDriver
import MacDriving
import PerceptionCore
import Testing

/// The engine roles over the fake tree: the window list with the window server's numbers, and the
/// scene of the window that has the focus.
@Suite("MacDriver windows and scenes")
struct MacWindowsTests {

    static let front = CGRect(x: 0, y: 0, width: 500, height: 400)
    static let back = CGRect(x: 600, y: 0, width: 300, height: 200)

    private func reader() -> FakeTreeReader {
        let button = MacTreeNode(role: "AXButton", title: "OK", frame: CGRect(x: 10, y: 10, width: 50, height: 20), actions: ["AXPress"])
        return FakeTreeReader(windows: [7: [
            (MacWindowSummary(index: 0, role: "AXWindow", title: "Back", frame: Self.back, isMain: true), Trees.window("Back", Self.back, children: [])),
            (MacWindowSummary(index: 1, role: "AXWindow", title: "Hidden", frame: Self.back, isMinimized: true), Trees.window("Hidden", Self.back, children: [])),
            (MacWindowSummary(index: 2, role: "AXWindow", title: "Front", frame: Self.front, isFocused: true), Trees.window("Front", Self.front, children: [button])),
        ]])
    }

    @Test("Windows skip the minimized ones and carry the server's number matched by frame")
    func windows() async throws {
        let listing = MacWindows(reader: reader(), serverWindows: { _ in [(number: 91, frame: Self.front.offsetBy(dx: 0.4, dy: 0))] })
        let rows = try await listing.windows(ownedBy: 7)
        #expect(rows.map(\.title) == ["Back", "Front"])
        #expect(rows.map(\.number) == [0, 91])
    }

    @Test("The scene is the focused window's, its frame the window's")
    func scene() async throws {
        let scene = try await MacScenes(reader: reader()).currentScene(of: 7)
        #expect(scene.scene.windowTitle == "Front" && scene.frame == Self.front)
        #expect(scene.scene.elements.map(\.label) == ["OK"] && scene.scene.elements.first?.id == "m0")
    }

    @Test("A process with no window throws")
    func none() async throws {
        await #expect(throws: MacTreeFailure.windowNotFound(index: 0)) { try await MacScenes(reader: reader()).currentScene(of: 8) }
    }
}
