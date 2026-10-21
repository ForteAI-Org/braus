import CoreGraphics
import Foundation
import MacDriver
import Synchronization
import Testing

/// The launch styles that keep the person's app in front when an app activates itself (#51): which
/// style a launch uses and what each does.
@Suite("MacDriver launch styles")
struct MacLaunchStyleTests {

    static let music = MacApp(bundleID: "com.apple.Music", url: URL(fileURLWithPath: "/System/Applications/Music.app"), names: ["Musica", "Music"])
    static let person = MacRunningApp(processID: 42, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    private func launcher(selfActivates: Bool) -> (MacLauncher, FakeWorkspace) {
        let workspace = FakeWorkspace(apps: [Self.music], front: Self.person, selfActivates: selfActivates)
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300), isFocused: true)
        let reader = FakeTreeReader(windows: [500: [(summary, Trees.window("Musica", summary.frame!, children: []))]])
        let launcher = MacLauncher(workspace: workspace, reader: reader, windowTimeout: .milliseconds(200), pollInterval: .milliseconds(10))
        return (launcher, workspace)
    }

    @Test("By default a self-activating app is launched in revert: sent back at once, never left in front")
    func revertByDefault() async throws {
        let (launcher, workspace) = launcher(selfActivates: true)
        let report = try await launcher.open("Musica")
        #expect(report.style == .revert && report.reverts == 1 && !report.selfActivated)
        #expect(workspace.state.withLock { ($0.styles, $0.front?.processID) } == ([.revert], 42))
    }

    @Test("In plain, a self-activating app takes the front and the focus guard brings the person's app back")
    func plain() async throws {
        let (launcher, _) = launcher(selfActivates: true)
        let report = try await launcher.open("Musica", style: .plain)
        #expect(report.style == .plain && report.reverts == 0 && report.selfActivated && report.focusRestored)
    }

    @Test("An app that stays behind is launched in revert and nothing is sent back")
    func behaves() async throws {
        let (launcher, _) = launcher(selfActivates: false)
        let report = try await launcher.open("Musica")
        #expect(report.style == .revert && report.reverts == 0 && !report.selfActivated)
    }

    @Test("An app already running is not launched, whatever the style")
    func running() async throws {
        let workspace = FakeWorkspace(apps: [Self.music], front: Self.person,
                                      running: [MacRunningApp(processID: 500, bundleID: Self.music.bundleID)])
        let summary = MacWindowSummary(index: 0, role: "AXWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300), isFocused: true)
        let reader = FakeTreeReader(windows: [500: [(summary, Trees.window("Musica", summary.frame!, children: []))]])
        let report = try await MacLauncher(workspace: workspace, reader: reader).open("Musica", style: .plain)
        #expect(report.style == nil && report.wasRunning)
        #expect(workspace.state.withLock { $0.styles }.isEmpty)
    }
}
