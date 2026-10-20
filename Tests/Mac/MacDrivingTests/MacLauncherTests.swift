import CoreGraphics
import Foundation
import MacDriver
import Synchronization
import Testing

/// The launcher on a fake workspace and a fake tree: resolution by any of an app's names, the refused
/// apps, the wait for a first window, and giving the person back their front app.
@Suite("MacDriver launcher")
struct MacLauncherTests {

    static let notes = MacApp(bundleID: "com.apple.Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"),
                              names: ["Note", "Notes"])
    static let settings = MacApp(bundleID: "com.apple.systempreferences",
                                 url: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                 names: ["Impostazioni di Sistema", "System Settings"])
    static let vault = MacApp(bundleID: "com.example.vault", url: URL(fileURLWithPath: "/Applications/Vault.app"),
                              names: ["1Password 8"])
    static let person = MacRunningApp(processID: 42, bundleID: "com.google.Chrome", name: "Google Chrome")

    static let frame = CGRect(x: 100, y: 100, width: 600, height: 400)

    private func reader(sheet: Bool = false, windowAfterPolls: Int = 0, trusted: Bool = true) -> FakeTreeReader {
        var children: [MacTreeNode] = []
        if sheet {
            children.append(MacTreeNode(role: "AXSheet", frame: Self.frame, children: [
                MacTreeNode(role: "AXStaticText", value: "Benvenuto in Note"),
                MacTreeNode(role: "AXButton", title: "Continua"),
                MacTreeNode(role: "AXButton", title: "Non ora"),
            ]))
        }
        let summary = MacWindowSummary(index: 0, role: "AXWindow", subrole: "AXStandardWindow", title: "Note",
                                       frame: Self.frame, isMain: true, isFocused: true)
        let tree = Trees.window("Note", Self.frame, children: children)
        return FakeTreeReader(isTrusted: trusted, windows: [500: [(summary, tree)]], windowAfterPolls: windowAfterPolls)
    }

    private func launcher(_ workspace: FakeWorkspace, _ reader: FakeTreeReader) -> MacLauncher {
        MacLauncher(workspace: workspace, reader: reader, windowTimeout: .milliseconds(200), pollInterval: .milliseconds(5))
    }

    @Test("An app is found by any of its names, without case or accents, by bundle id and by path",
          arguments: ["note", "Notes", "NOTES.app", "com.apple.Notes", "/System/Applications/Notes.app"])
    func resolve(request: String) throws {
        let workspace = FakeWorkspace(apps: [Self.settings, Self.notes], front: Self.person)
        #expect(try launcher(workspace, reader()).resolve(request) == Self.notes)
    }

    @Test("Localized names with accents match either way")
    func accents() throws {
        let workspace = FakeWorkspace(apps: [Self.settings], front: Self.person)
        #expect(try launcher(workspace, reader()).resolve("impostazioni di sistema") == Self.settings)
        #expect(throws: MacLaunchFailure.notFound("Impostazioni")) { try launcher(workspace, reader()).resolve("Impostazioni") }
    }

    @Test("A password manager is refused before anything launches")
    func refused() async throws {
        let workspace = FakeWorkspace(apps: [Self.vault], front: Self.person)
        await #expect(throws: MacLaunchFailure.refused("1Password 8")) { try await launcher(workspace, reader()).open("1password 8") }
        #expect(workspace.state.withLock(\.launches).isEmpty)
        #expect(MacRefusedApps.refuses(MacApp(bundleID: "com.apple.Passwords", url: URL(fileURLWithPath: "/x.app"), names: ["Password"])))
    }

    @Test("Without accessibility permission nothing launches")
    func untrusted() async throws {
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person)
        await #expect(throws: MacLaunchFailure.notTrusted) { try await launcher(workspace, reader(trusted: false)).open("Note") }
        #expect(workspace.state.withLock(\.launches).isEmpty)
    }

    @Test("A background launch waits for the first window and leaves the person's app alone")
    func background() async throws {
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person)
        let report = try await launcher(workspace, reader(windowAfterPolls: 3)).open("Note")
        #expect(!report.wasRunning && report.processID == 500 && report.window?.title == "Note")
        #expect(!report.selfActivated && !report.focusRestored)
        #expect(workspace.state.withLock(\.activations).isEmpty)
        #expect(workspace.state.withLock(\.launches) == ["com.apple.Notes"])
    }

    @Test("In plain, an app that activates itself is let be, then the person's app comes back")
    func selfActivating() async throws {
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person, selfActivates: true)
        let report = try await launcher(workspace, reader()).open("Note", style: .plain)
        #expect(report.selfActivated && report.focusRestored && !report.personActedMeanwhile)
        #expect(workspace.state.withLock(\.activations) == [42])
    }

    @Test("In plain, if the person typed or clicked during the launch, their focus is left as they set it")
    func personActed() async throws {
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person, selfActivates: true)
        workspace.personActsNow()
        let report = try await launcher(workspace, reader()).open("Note", style: .plain)
        #expect(report.selfActivated && !report.focusRestored && report.personActedMeanwhile)
        #expect(workspace.state.withLock(\.activations).isEmpty)
    }

    @Test("A running app is not launched again")
    func alreadyRunning() async throws {
        let running = MacRunningApp(processID: 500, bundleID: "com.apple.Notes", name: "Note")
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person, running: [running])
        let report = try await launcher(workspace, reader()).open("Note")
        #expect(report.wasRunning && workspace.state.withLock(\.launches).isEmpty)
    }

    @Test("No window in time is reported, not thrown")
    func noWindow() async throws {
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person)
        let report = try await launcher(workspace, reader(windowAfterPolls: 1_000)).open("Note")
        #expect(report.window == nil && report.secondsWaited >= 0.2)
    }

    @Test("A first-run sheet is reported with its buttons")
    func sheet() async throws {
        let workspace = FakeWorkspace(apps: [Self.notes], front: Self.person)
        let report = try await launcher(workspace, reader(sheet: true)).open("Note")
        #expect(report.sheet == MacLaunchReport.Sheet(title: "Benvenuto in Note", buttons: ["Continua", "Non ora"]))
    }

    @Test("a window is left in front, for the seat, only when it came forward, stayed, and the person did not act")
    func leftInFront() {
        #expect(MacFocusGuard.leavesInFront(selfActivated: true, focusRestored: false, personActed: false))
        #expect(!MacFocusGuard.leavesInFront(selfActivated: true, focusRestored: true, personActed: false))
        #expect(!MacFocusGuard.leavesInFront(selfActivated: true, focusRestored: false, personActed: true))
        #expect(!MacFocusGuard.leavesInFront(selfActivated: false, focusRestored: false, personActed: false))
    }
}
