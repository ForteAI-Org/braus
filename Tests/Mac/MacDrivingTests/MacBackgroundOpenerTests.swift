import CoreGraphics
import Foundation
@testable import MacDriver
import Synchronization
import Testing

/// The background operations on fakes: a Settings pane by id or by name, read back by the selected
/// sidebar row of the recorded Settings tree; reveal through Finder's script or through accessibility;
/// a file opened with an app and found by its window's document.
@Suite("MacDriver background operations")
struct MacBackgroundOpenerTests {

    static let settings = MacApp(bundleID: "com.apple.systempreferences",
                                 url: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                 names: ["Impostazioni di Sistema", "System Settings"])
    static let finder = MacApp(bundleID: "com.apple.finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                               names: ["Finder"])
    static let textEdit = MacApp(bundleID: "com.apple.TextEdit", url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                 names: ["TextEdit"])
    static let person = MacRunningApp(processID: 42, bundleID: "com.google.Chrome")
    static let frame = CGRect(x: 0, y: 0, width: 800, height: 600)

    let folder: URL
    let file: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Braus test \(UUID().uuidString)")
        file = folder.appendingPathComponent("Braus test.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Braus test".utf8).write(to: file)
    }

    private func opener(
        _ workspace: FakeWorkspace, _ reader: FakeTreeReader, finder: FakeFinderScripting = FakeFinderScripting(permitted: false)
    ) -> MacBackgroundOpener {
        MacBackgroundOpener(
            launcher: MacLauncher(workspace: workspace, reader: reader, windowTimeout: .milliseconds(100),
                                  pollInterval: .milliseconds(5)),
            finder: finder,
            actor : reader
        )
    }

    // MARK: Settings

    private func settingsSetup() throws -> (FakeWorkspace, FakeTreeReader) {
        let running = MacRunningApp(processID: 300, bundleID: Self.settings.bundleID)
        let workspace = FakeWorkspace(apps: [Self.settings], front: Self.person, running: [running])
        let summary = MacWindowSummary(index: 0, role: "AXWindow", title: "Tastiera", frame: Self.frame, isMain: true, isFocused: true)
        let reader = FakeTreeReader(windows: [300: [(summary, try Trees.recorded("settings-keyboard"))]])
        return (workspace, reader)
    }

    @Test("The sidebar lists every pane with its id, name and selection; the link id drops a sub-pane")
    func panes() throws {
        let panes = MacSettingsPane.panes(in: try Trees.recorded("settings-keyboard"))
        #expect(panes.count == 15)
        #expect(panes.filter(\.isSelected).map(\.id) == ["com.apple.Keyboard-Settings.extension"])
        #expect(panes.first { $0.name == "Trackpad" }?.id == "com.apple.Trackpad-Settings.extension")
        #expect(panes.first { $0.id.hasPrefix("com.apple.Touch-ID") }?.linkID == "com.apple.Touch-ID-Settings.extension")
    }

    @Test("A pane by id opens its link and is read back as the selected row")
    func paneByID() async throws {
        let (workspace, reader) = try settingsSetup()
        let report = try await opener(workspace, reader).openSettingsPane("com.apple.Keyboard-Settings.extension")
        #expect(report.isVerified && report.processID == 300)
        #expect(workspace.state.withLock(\.links) == [URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")])
    }

    @Test("A pane by name is looked up in the sidebar; a row that stays elsewhere is not verified")
    func paneByName() async throws {
        let (workspace, reader) = try settingsSetup()
        let report = try await opener(workspace, reader).openSettingsPane("trackpad")
        #expect(workspace.state.withLock(\.links) == [URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")])
        #expect(!report.isVerified && report.reason?.contains("Trackpad") == true)
    }

    @Test("A name no sidebar row has is refused before any link")
    func unknownPane() async throws {
        let (workspace, reader) = try settingsSetup()
        await #expect(throws: MacOpenFailure.paneNotFound("Giardino")) { try await opener(workspace, reader).openSettingsPane("Giardino") }
        #expect(workspace.state.withLock(\.links).isEmpty)
    }

    // MARK: Reveal

    private func finderSetup(refusesSelection: Bool = false) -> (FakeWorkspace, FakeTreeReader) {
        let running = MacRunningApp(processID: 636, bundleID: Self.finder.bundleID)
        let workspace = FakeWorkspace(apps: [Self.finder], front: Self.person, running: [running])
        let row = MacTreeNode(role: "AXRow", isSelected: false, children: [
            MacTreeNode(role: "AXCell", children: [MacTreeNode(role: "AXTextField", value: file.lastPathComponent)]),
        ])
        let window = Trees.window(folder.lastPathComponent, Self.frame, children: [
            MacTreeNode(role: "AXOutline", children: [row]),
        ])
        let summary = MacWindowSummary(index: 0, role: "AXWindow", title: folder.lastPathComponent, frame: Self.frame, isFocused: true)
        return (workspace, FakeTreeReader(windows: [636: [(summary, window)]], refusesSelection: refusesSelection))
    }

    @Test("With Finder's scripting permitted, reveal is Finder's own and read back by its selection")
    func revealByScript() async throws {
        let (workspace, reader) = finderSetup()
        let finder = FakeFinderScripting(permitted: true)
        let report = try await opener(workspace, reader, finder: finder).reveal(file.path)
        #expect(report.isVerified && report.route.hasPrefix("api"))
        #expect(finder.revealed.withLock { $0 } == [file.standardizedFileURL])
        #expect(workspace.state.withLock(\.opened).isEmpty)
    }

    @Test("A script whose selection is another item is not verified")
    func revealByScriptMissed() async throws {
        let (workspace, reader) = finderSetup()
        let report = try await opener(workspace, reader, finder: FakeFinderScripting(permitted: true, ignoresReveal: true))
            .reveal(file.path)
        #expect(!report.isVerified && report.reason?.contains("selection") == true)
    }

    @Test("Without the permission, the folder opens behind and the row is selected through accessibility")
    func revealByAccessibility() async throws {
        let (workspace, reader) = finderSetup()
        let report = try await opener(workspace, reader).reveal(file.path)
        #expect(report.isVerified && report.route.hasPrefix("accessibility") && report.window?.title == folder.lastPathComponent)
        #expect(workspace.state.withLock { $0.opened.map(\.items) } == [[folder.standardizedFileURL]])
        #expect(reader.selections.withLock { $0[636] } == [0, 0])
    }

    @Test("A view that refuses the selection write is reported, not thrown")
    func revealRefused() async throws {
        let (workspace, reader) = finderSetup(refusesSelection: true)
        let report = try await opener(workspace, reader).reveal(file.path)
        #expect(!report.isVerified && report.reason?.contains("-25205") == true)
    }

    @Test("A path that does not exist is refused")
    func revealMissing() async throws {
        let (workspace, reader) = finderSetup()
        let missing = folder.appendingPathComponent("nope.txt").path
        await #expect(throws: MacOpenFailure.itemNotFound(missing)) { try await opener(workspace, reader).reveal(missing) }
    }

    @Test("In column view the item is the list's child that holds its name")
    func columnItem() {
        let group = MacTreeNode(role: "AXGroup", children: [
            MacTreeNode(role: "AXImage"), MacTreeNode(role: "AXTextField", value: "altro.txt"),
        ])
        let window = Trees.window("T", Self.frame, children: [MacTreeNode(role: "AXBrowser", children: [
            MacTreeNode(role: "AXList", children: [MacTreeNode(role: "AXGroup"), group]),
        ])])
        #expect(MacTreeLookup.finderItem(named: "altro.txt", in: window)?.path == [0, 0, 1])
    }

    // MARK: Open with

    @Test("A file opened with a named app is read back by its window's document")
    func openWith() async throws {
        let workspace = FakeWorkspace(apps: [Self.textEdit], front: Self.person)
        let summary = MacWindowSummary(index: 0, role: "AXWindow", title: "x", frame: Self.frame, isFocused: true,
                                       document: file.absoluteString)
        let reader = FakeTreeReader(windows: [500: [(summary, Trees.window("x", Self.frame, children: []))]])
        let report = try await opener(workspace, reader).open(file.path, with: "TextEdit")
        #expect(report.isVerified && report.app == Self.textEdit)
        #expect(workspace.state.withLock { $0.opened.map(\.app) } == ["com.apple.TextEdit"])
    }

    @Test("Without an app the default one opens it; a window of another file is not a read-back")
    func openWithDefault() async throws {
        let workspace = FakeWorkspace(apps: [Self.textEdit], front: Self.person)
        let summary = MacWindowSummary(index: 0, role: "AXWindow", title: "Altro.txt", frame: Self.frame, isFocused: true)
        let reader = FakeTreeReader(windows: [500: [(summary, Trees.window("Altro.txt", Self.frame, children: []))]])
        let report = try await opener(workspace, reader).open(file.path, with: nil)
        #expect(report.app == Self.textEdit && !report.isVerified)
    }

    @Test("AppleScript literals escape quotes and backslashes")
    func quoting() {
        #expect(LiveFinderScripting.quoted(#"/a "b"\c"#) == #""/a \"b\"\\c""#)
    }
}
