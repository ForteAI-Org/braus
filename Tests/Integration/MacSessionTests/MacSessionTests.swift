import AppAdapters
import AutomationMCP
import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import LocalMCP
import MacDriver
import MacDriving
import Memory
@testable import MacSession
import PerceptionCore
import Router
@testable import SQLiteMemory
import Synchronization
import Testing
import WindowServerListing

/// The MacDriver wired into the sessions and the tools, on fakes: no app, no tree, no desktop.
@MainActor
@Suite("Mac session")
struct MacSessionTests {

    // MARK: Fixtures

    nonisolated static let pid: pid_t = 500
    nonisolated static let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    nonisolated static let notes = MacApp(bundleID: "com.example.notes", url: URL(fileURLWithPath: "/Applications/Notes.app"),
                              names: ["Notes"])
    nonisolated static let person = MacRunningApp(processID: 99, bundleID: "com.example.person", name: "Person")

    /// A window covered by twelve buttons: rich for `MacCoverage`.
    nonisolated static let rich = MacTreeNode(role: "AXWindow", title: "Notes", frame: frame, children: (0..<12).map { index in
        MacTreeNode(role: "AXButton", title: "B\(index)",
                    frame: CGRect(x: Double(index % 4) * 200, y: Double(index / 4) * 200, width: 200, height: 200),
                    actions: ["AXPress"])
    })

    /// A window with one group and nothing to act on: sparse.
    nonisolated static let sparse = MacTreeNode(role: "AXWindow", title: "Canvas", frame: frame, children: [
        MacTreeNode(role: "AXGroup", frame: frame),
    ])

    private func knowledge() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mac-session-\(UUID().uuidString)")
    }

    private func roles(_ reader: TreeStub, person: (any MacPersonWatching)? = nil,
                       controls: any ControlPressing = NoControls(),
                       delivery: NoDelivery = NoDelivery()) -> MacRoles {
        MacRoles(reader: reader, actor: reader, delivery: delivery, person: person,
                 notifications: QuietNotifications(), controls: controls,
                 serverWindows: { _ in [(number: 7, frame: Self.frame)] })
    }

    private func session(_ tree: MacTreeNode, workspace: WorkspaceStub = WorkspaceStub(),
                         person: (any MacPersonWatching)? = nil,
                         delivery: NoDelivery = NoDelivery()) -> (MacAutomationSession, TreeStub) {
        let reader = TreeStub(tree)
        return (MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(reader, person: person, delivery: delivery),
                                     workspace: workspace, leases: MacAppLeases()), reader)
    }

    /// The JSON a tool answered, out of its MCP text content.
    private func answer(_ result: JSONValue) throws -> JSONValue {
        if result["structuredContent"] != .null { return result["structuredContent"] }
        let text = try #require(result["content"].array?.first?["text"].string)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: MacAutomationSession

    @Test("a rich window opens on the MacDriver and a click runs on rung 1")
    func richWindowActs() async throws {
        let (session, reader) = session(Self.rich)
        let scene = try await session.open(application: "Notes", window: nil)
        #expect(session.id != nil)
        #expect(scene.elements.contains { $0.label == "B3" })
        #expect(session.memoryApplication == Self.notes.bundleID)
        _ = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(reader.steps.withLock { $0 } == ["perform AXPress [3]"])
        await session.close()
        #expect(session.id == nil)
    }

    @Test("a click whose effect shows in the tree is found_acted; one that changes nothing is a ghost")
    func clickReadBack() async throws {
        func window(_ display: String) -> MacTreeNode {
            var tree = Self.rich
            tree.children.append(MacTreeNode(role: "AXStaticText", value: display,
                                             frame: CGRect(x: 0, y: 0, width: 800, height: 40)))
            return tree
        }
        let reader = TreeStub(window("7×6"), pressed: ["B3": window("42")])
        let session = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(reader), workspace: WorkspaceStub(),
                                           leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        let pressed = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(pressed.kind == .foundActed)
        #expect(pressed.message.contains("now reads '42'"))
        let again = try await session.act(target: "B5", verb: .click, section: nil, desiredState: nil)
        #expect(again.kind == .actedUnverified && again.message.contains("identical scene"))
        await session.close()
    }

    @Test("a sparse window is handed back with its coverage, and no session stays open")
    func sparseWindowHandsOff() async throws {
        let (session, _) = session(Self.sparse)
        await #expect(throws: MacHandoff.self) { try await session.open(application: "Notes", window: nil) }
        #expect(session.id == nil)
        #expect(session.openedCoverage?.isRich == false)
    }

    @Test("a window left in front of the person's is handed to the seat")
    func leftInFrontHandsOff() async throws {
        let workspace = WorkspaceStub(selfActivates: true, restores: false)
        let (session, _) = session(Self.rich, workspace: workspace)
        do {
            _ = try await session.open(application: "Notes", window: nil)
            Issue.record("expected a handoff")
        } catch let handoff as MacHandoff {
            #expect(handoff == .leftInFront(bundleID: Self.notes.bundleID))
        }
    }

    /// A session whose every press makes the app activate itself, as Notes' "New note" does.
    private func selfActivatingSession(_ workspace: WorkspaceStub) -> MacAutomationSession {
        let reader = TreeStub(Self.rich) {
            workspace.front.withLock { $0 = MacRunningApp(processID: Self.pid, bundleID: Self.notes.bundleID) }
        }
        return MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(reader), workspace: workspace,
                                    leases: MacAppLeases())
    }

    @Test("an app that comes in front during a click is sent back, and the seat contains it from the next call")
    func actSelfActivationRestored() async throws {
        let workspace = WorkspaceStub()
        let session = selfActivatingSession(workspace)
        _ = try await session.open(application: "Notes", window: nil)
        let outcome = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(outcome.message.contains("the person's app is back in front"))
        #expect(await workspace.frontmost()?.processID == Self.person.processID)
        await #expect(throws: MacHandoff.cameInFront(bundleID: Self.notes.bundleID)) { try await session.observe() }
        #expect(session.id == nil)
    }

    @Test("an app that came in front at launch goes to the seat even when the person's app came back")
    func launchSelfActivationHandsOff() async throws {
        let session = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(TreeStub(Self.rich)),
                                           workspace: WorkspaceStub(selfActivates: true), leases: MacAppLeases())
        await #expect(throws: MacHandoff.cameInFront(bundleID: Self.notes.bundleID)) {
            try await session.open(application: "Notes", window: nil)
        }
    }

    @Test("an app that comes in front and stays there says so, and is handed to the seat at the next call")
    func actSelfActivationHandsOff() async throws {
        let workspace = WorkspaceStub(restores: false)
        let session = selfActivatingSession(workspace)
        _ = try await session.open(application: "Notes", window: nil)
        let outcome = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(outcome.message.contains("it could not be sent back"))
        await #expect(throws: MacHandoff.cameInFront(bundleID: Self.notes.bundleID)) {
            try await session.act(target: "B4", verb: .click, section: nil, desiredState: nil)
        }
        #expect(session.id == nil)
    }

    @Test("the engine's own control press bringing the app in front is caught by the call's guard")
    func controlPressSelfActivation() async throws {
        let workspace = WorkspaceStub()
        let controls = ActivatingControls {
            workspace.front.withLock { $0 = MacRunningApp(processID: Self.pid, bundleID: Self.notes.bundleID) }
        }
        let session = MacAutomationSession(knowledgeDirectory: knowledge(),
                                           roles: roles(TreeStub(Self.rich), controls: controls), workspace: workspace,
                                           leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        let outcome = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(outcome.message.contains("the person's app is back in front"))
        #expect(await workspace.frontmost()?.processID == Self.person.processID)
        await #expect(throws: MacHandoff.cameInFront(bundleID: Self.notes.bundleID)) { try await session.observe() }
    }

    @Test("select stops after a first click that brought the app in front: the seat chooses the item")
    func selectStopsAfterFrontSteal() async throws {
        let workspace = WorkspaceStub()
        let reader = TreeStub(Self.rich) {
            workspace.front.withLock { $0 = MacRunningApp(processID: Self.pid, bundleID: Self.notes.bundleID) }
        }
        let session = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(reader), workspace: workspace,
                                           leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        let outcome = try await session.select(control: "B3", item: "B4")
        #expect(outcome.message.contains("came in front"))
        #expect(reader.steps.withLock { $0 }.count == 1)
    }

    @Test("an app that comes forward at launch with a dialog is left in front for the person and goes to the seat")
    func launchDialogLeftInFront() async throws {
        let workspace = WorkspaceStub(selfActivates: true, dialog: true)
        let session = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(TreeStub(Self.rich)),
                                           workspace: workspace, leases: MacAppLeases())
        await #expect(throws: MacHandoff.dialogInFront(bundleID: Self.notes.bundleID)) {
            try await session.open(application: "Notes", window: nil)
        }
        #expect(await workspace.frontmost()?.processID == Self.pid, "the dialog stays in front")
    }

    @Test("every launch is logged with what it did to the front; an app already running is not")
    func launchLog() async throws {
        let directory = knowledge()
        let session = MacAutomationSession(knowledgeDirectory: directory, roles: roles(TreeStub(Self.rich)),
                                           workspace: WorkspaceStub(selfActivates: true), leases: MacAppLeases())
        await #expect(throws: MacHandoff.self) { try await session.open(application: "Notes", window: nil) }
        let entries = MacLaunchLog(directory: directory).entries()
        #expect(entries.count == 1)
        #expect(entries.first?.bundleID == Self.notes.bundleID && entries.first?.selfActivated == true)
        #expect(entries.first?.focusRestored == true && entries.first?.dialogInFront == false)
    }

    @Test("a click that leaves the front alone keeps the app on the MacDriver")
    func actWithoutActivationStays() async throws {
        let workspace = WorkspaceStub()
        let session = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(TreeStub(Self.rich)),
                                           workspace: workspace, leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        _ = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        _ = try await session.observe()
        #expect(session.id != nil)
        await session.close()
    }

    @Test("a key whose key-window records were not taken back is delivered once and the outcome says so")
    func unrestoredPreparationIsNoted() async throws {
        let (unrestored, _) = session(Self.rich, delivery: NoDelivery(leavesPreparation: true))
        _ = try await unrestored.open(application: "Notes", window: nil)
        let outcome = try await unrestored.deliver(.pressKey(KeyChord(.return), times: 1), section: nil)
        #expect(outcome.kind != .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("could not take back the key-window records"), Comment(rawValue: outcome.message))
        let next = try await unrestored.deliver(.pressKey(KeyChord(.return), times: 1), section: nil)
        #expect(next.message.contains("could not take back the key-window records"), "each call notes its own")
        let (clean, _) = session(Self.rich)
        _ = try await clean.open(application: "Notes", window: nil)
        let fine = try await clean.deliver(.pressKey(KeyChord(.return), times: 1), section: nil)
        #expect(!fine.message.contains("key-window records"), Comment(rawValue: fine.message))
    }

    @Test("rule 6: the person touched the app after its scene was read, so the click is refused, never retried")
    func personFirst() async throws {
        let (session, reader) = session(Self.rich, person: AlwaysTouched())
        _ = try await session.open(application: "Notes", window: nil)
        let outcome = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(outcome.kind == .refused)
        #expect(outcome.message.contains("nothing was sent. The person changed the app; read it again."),
                Comment(rawValue: outcome.message))
        #expect(reader.steps.withLock { $0 }.isEmpty)
    }

    // MARK: M1: the person first on the controls' fast path, through the runtime

    /// The rich window with a pop-up button in place of its first button.
    nonisolated static let exportWindow = MacTreeNode(role: "AXWindow", title: "Export", frame: frame, children:
        [MacTreeNode(role: "AXPopUpButton", title: "Qualita", value: "Alta", frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                     actions: ["AXPress"])]
        + (1..<12).map { index in
            MacTreeNode(role: "AXButton", title: "B\(index)",
                        frame: CGRect(x: Double(index % 4) * 200, y: Double(index / 4) * 200, width: 200, height: 200),
                        actions: ["AXPress"])
        })

    @Test("M1 through the runtime and the real MacControls: the person touched the app after the read, so the pop-up's AXPress is vetoed and the click refused, nothing sent, no menu call, nothing passed")
    func personFirstOnTheFastPath() async throws {
        let directory = knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = TreeStub(Self.exportWindow)
        let menus = CountingMenus()
        let delivery = CountingDelivery()
        let roles = MacRoles(reader: reader, actor: reader, delivery: delivery, person: AlwaysTouched(),
                             notifications: QuietNotifications(), controls: nil, menus: menus,
                             serverWindows: { _ in [(number: 7, frame: Self.frame)] })
        let session = MacAutomationSession(knowledgeDirectory: directory, roles: roles, workspace: WorkspaceStub(),
                                           leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        // A runtime over the same archive, for its recorder only: the call is begun and ended as the MCP layer does.
        let recorder = MacEngineRuntime(knowledgeDirectory: directory, roles: roles).recorder(Self.call)
        let outcome = try await recorded(by: recorder, target: "Qualita") {
            try await CallRecorder.$current.withValue(recorder) {
                try await session.act(target: "Qualita", verb: .click, section: nil, desiredState: nil)
            }
        }
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
        #expect(outcome.check?.verdict != .passed)
        #expect(reader.steps.withLock { $0 }.isEmpty, "no AXPress")
        #expect(menus.presses.withLock { $0 } == 0 && delivery.events.withLock { $0 } == 0, "no menu call, no event")
        await session.close()
        let (effects, verdicts) = try await archived(directory)
        #expect(effects == ["none:person_acted"], "\(effects)")
        #expect(!verdicts.contains { $0.hasSuffix(":passed") }, "\(verdicts)")
    }

    @Test("M1 positive control through the runtime: with no touch the real MacControls press the pop-up, as before")
    func fastPathWithoutTouch() async throws {
        let reader = TreeStub(Self.exportWindow)
        let roles = MacRoles(reader: reader, actor: reader, delivery: CountingDelivery(), person: nil,
                             notifications: QuietNotifications(), controls: nil, menus: CountingMenus(),
                             serverWindows: { _ in [(number: 7, frame: Self.frame)] })
        let session = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles, workspace: WorkspaceStub(),
                                           leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        _ = try await session.act(target: "Qualita", verb: .click, section: nil, desiredState: nil)
        #expect(reader.steps.withLock { $0 } == ["perform AXPress [0]"])
        await session.close()
    }

    /// The rich window with an open menu's item "PDF" in place of its first button; `MenuOpen` lists the menu.
    nonisolated static let menuWindow = MacTreeNode(role: "AXWindow", title: "Export", frame: frame, children:
        [MacTreeNode(role: "AXMenuItem", title: "PDF", frame: CGRect(x: 0, y: 0, width: 200, height: 200), actions: ["AXPress"])]
        + (1..<12).map { index in
            MacTreeNode(role: "AXButton", title: "B\(index)",
                        frame: CGRect(x: Double(index % 4) * 200, y: Double(index / 4) * 200, width: 200, height: 200),
                        actions: ["AXPress"])
        })

    /// The engine over the runtime's own scenes, actuator, real MacControls and settler, with a census that shows a
    /// menu open over the window, reporting to `recorder`.
    private func menuEngine(_ runtime: MacEngineRuntime, recorder: CallRecorder) -> ActionEngine {
        ActionEngine(ActionEngine.Dependencies(
            scenes: runtime.scenes, actuator: runtime.actuator, windows: MenuOpen(), controls: runtime.controls,
            expectations: runtime.memory, observer: recorder, settling: runtime.settling, countsNativeTextChange: true
        ), pause: { _ in })
    }

    private static let pdf = ActionRequest(processID: 42, bundleID: notes.bundleID, appName: "Notes", target: "PDF", verb: .click)

    @Test("M1 in an open menu, through the engine and the real MacControls: a touch found at the first check, or only at the last one before the delegation, refuses the choice: no menu call, no step, no event, nothing archived as passed",
          arguments: [1, 2])
    func personFirstInTheOpenMenu(touchFrom check: Int) async throws {
        let directory = knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = TreeStub(Self.menuWindow)
        let menus = CountingMenus()
        let delivery = CountingDelivery()
        let person = TouchFrom(check)
        let roles = MacRoles(reader: reader, actor: reader, delivery: delivery, person: person,
                             notifications: QuietNotifications(), controls: nil, menus: menus,
                             serverWindows: { _ in [(number: 7, frame: Self.frame)] })
        let runtime = MacEngineRuntime(knowledgeDirectory: directory, roles: roles)
        let recorder = runtime.recorder(Self.call)
        let outcome = try await recorded(by: recorder, target: "PDF") {
            await menuEngine(runtime, recorder: recorder).act(Self.pdf)
        }
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
        #expect(person.asked.withLock { $0 } == check, "the touch was found at check \(check), and nothing asked again")
        #expect(menus.presses.withLock { $0 } == 0, "the menu controller was not called")
        #expect(reader.steps.withLock { $0 }.isEmpty && delivery.events.withLock { $0 } == 0, "no step, no event")
        let (effects, verdicts) = try await archived(directory)
        #expect(effects == ["none:the person changed the app; read it again"], "\(effects)")
        #expect(!verdicts.contains { $0.hasSuffix(":passed") }, "\(verdicts)")
    }

    @Test("M1 positive control in the open menu: with no touch the real MacControls delegate the choice once, as before")
    func openMenuWithoutTouch() async throws {
        let directory = knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = TreeStub(Self.menuWindow)
        let menus = CountingMenus()
        let roles = MacRoles(reader: reader, actor: reader, delivery: CountingDelivery(), person: nil,
                             notifications: QuietNotifications(), controls: nil, menus: menus,
                             serverWindows: { _ in [(number: 7, frame: Self.frame)] })
        let runtime = MacEngineRuntime(knowledgeDirectory: directory, roles: roles)
        let outcome = await menuEngine(runtime, recorder: runtime.recorder(Self.call)).act(Self.pdf)
        #expect(menus.presses.withLock { $0 } == 1, Comment(rawValue: outcome.message))
        // The census still lists the menu, so the choice is unverified: the press went out, once.
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        await runtime.service.close()
    }

    // MARK: M2: a click judged on a window that did not answer in full, through the session and the archive

    /// A rich window of twelve buttons named by words, which a scene difference counts (a label with digits
    /// is a measurement to it).
    nonisolated static let commands = MacTreeNode(role: "AXWindow", title: "Notes", frame: frame, children:
        ["Apri", "Salva", "Stampa", "Esporta", "Chiudi", "Copia", "Incolla", "Taglia", "Trova", "Annulla", "Ripeti", "Aiuto"]
            .enumerated().map { index, title in
                MacTreeNode(role: "AXButton", title: title,
                            frame: CGRect(x: Double(index % 4) * 200, y: Double(index / 4) * 200, width: 200, height: 200),
                            actions: ["AXPress"])
            })

    /// `commands` after "Apri" is pressed: Annulla, Ripeti and Aiuto gone, and, when `unanswered`, an element
    /// that did not answer at the place of Annulla.
    nonisolated static func pressedWindow(unanswered: Bool) -> MacTreeNode {
        var after = commands
        after.children = Array(after.children.prefix(9))
        if unanswered {
            after.children.append(MacTreeNode(role: "AXUnknown", unread: MacUnread(cause: .timedOut, element: true)))
        }
        return after
    }

    @Test("M2 through the session and the archive: a click whose after-window did not answer in full learns no removal and no success; read in full, it learns the removal as before",
          arguments: [true, false])
    func unansweredAfterClick(unanswered: Bool) async throws {
        let directory = knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = TreeStub(Self.commands, pressed: ["Apri": Self.pressedWindow(unanswered: unanswered)])
        let roles = MacRoles(reader: reader, actor: reader, delivery: CountingDelivery(), person: nil,
                             notifications: QuietNotifications(), controls: nil, menus: CountingMenus(),
                             serverWindows: { _ in [(number: 7, frame: Self.frame)] })
        let session = MacAutomationSession(knowledgeDirectory: directory, roles: roles, workspace: WorkspaceStub(),
                                           leases: MacAppLeases())
        _ = try await session.open(application: "Notes", window: nil)
        let recorder = MacEngineRuntime(knowledgeDirectory: directory, roles: roles).recorder(Self.call)
        let outcome = try await recorded(by: recorder, target: "Apri") {
            try await CallRecorder.$current.withValue(recorder) {
                try await session.act(target: "Apri", verb: .click, section: nil, desiredState: nil)
            }
        }
        await session.close()
        #expect(reader.steps.withLock { $0 } == ["perform AXPress [0]"], "the click went out once")
        let rows = try await archiveRows(directory, [
            "SELECT o.target_label || ':' || v.verdict FROM memory_operation_verifications o "
                + "JOIN memory_verifications v ON v.event_id = o.event_id",
            "SELECT observed_effect_kind FROM memory_agent_actions WHERE observed_effect_kind IS NOT NULL",
            "SELECT limit_kind FROM memory_operation_verification_limits",
            "SELECT operation FROM brain_applications WHERE operation = 'record'",
            "SELECT outcome || ':' || COALESCE(reason, '') FROM brain_relation_evaluations",
        ])
        if unanswered {
            #expect(outcome.kind == .actedUnverified && outcome.check?.verdict == .unknown, Comment(rawValue: outcome.message))
            #expect(rows[0] == ["Apri:unknown"], "\(rows[0])")
            #expect(rows[1].isEmpty, "no effect observed: \(rows[1])")
            #expect(rows[2].contains("unattributed"), "\(rows[2])")
            #expect(rows[3].isEmpty, "no projection applied: \(rows[3])")
            #expect(rows[4].allSatisfy { $0 == "excluded:verdict_unknown" } && !rows[4].isEmpty, "\(rows[4])")
        } else {
            #expect(outcome.kind == .foundActed && outcome.check?.verdict == .passed, Comment(rawValue: outcome.message))
            #expect(rows[0] == ["Apri:passed"] && rows[1] == ["elementsDisappeared"], "\(rows)")
            #expect(rows[3] == ["record"], "the projection applied as before: \(rows[3])")
            #expect(!rows[4].contains { $0.hasPrefix("contradicted") }, "\(rows[4])")
        }
    }

    /// Flushes and closes the archive in `directory`, then answers each query's first column as text.
    private func archiveRows(_ directory: URL, _ queries: [String]) async throws -> [[String]] {
        let service = MemoryService.shared(for: directory)
        #expect(await service.flush(within: .seconds(10)))
        await service.close()
        let archive = try SQLiteConnection(path: directory.appendingPathComponent("memory.sqlite").path, readOnly: true)
        defer { archive.close() }
        return try queries.map { try archive.query($0) { try $0.text(0) ?? "" } }
    }

    private static let call = ActionContext(source: .app, streamID: "m1", traceID: "m1", sessionID: "s1")

    /// Runs `act` as one call `recorder` begins and ends, as the MCP layer does.
    private func recorded(by recorder: CallRecorder, target: String,
                          _ act: () async throws -> ActOutcome) async throws -> ActOutcome {
        try await recorder.begin(.act(target: target, verb: .click, value: nil, section: nil),
                                 app: AppContextIdentity(bundleID: Self.notes.bundleID))
        let outcome = try await act()
        try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message), tool: .act,
                               check: outcome.withStatedCheck.check)
        return outcome
    }

    /// What the archive in `directory` kept, once flushed and closed: each call's effect as `performed:reason`, and
    /// each verification as `label:verdict`.
    private func archived(_ directory: URL) async throws -> (effects: [String], verdicts: [String]) {
        let service = MemoryService.shared(for: directory)
        #expect(await service.flush(within: .seconds(10)))
        await service.close()
        let archive = try SQLiteConnection(path: directory.appendingPathComponent("memory.sqlite").path, readOnly: true)
        defer { archive.close() }
        let effects = try archive.query(
            "SELECT performed || ':' || COALESCE(not_sent_reason, '') FROM memory_call_effects ORDER BY event_id"
        ) { try $0.text(0) ?? "" }
        let verdicts = try archive.query(
            "SELECT o.target_label || ':' || v.verdict FROM memory_operation_verifications o "
                + "JOIN memory_verifications v ON v.event_id = o.event_id ORDER BY o.event_id"
        ) { try $0.text(0) ?? "" }
        return (effects, verdicts)
    }

    @Test("a password manager is refused at open")
    func passwordManagerRefused() async throws {
        let onePassword = MacApp(bundleID: "com.1password.1password", url: URL(fileURLWithPath: "/Applications/1Password.app"),
                                 names: ["1Password"])
        let (session, _) = session(Self.rich, workspace: WorkspaceStub(apps: [onePassword]))
        await #expect(throws: AutomationFailure.self) { try await session.open(application: "1Password", window: nil) }
    }

    // MARK: The MacDriver behind the app's router

    /// The router as the app builds it for a worker or an external client, the MacDriver on a fake tree
    /// and workspace as its native session.
    private func appRouter(_ tree: MacTreeNode, desktop: SessionStub, web: SessionStub) -> RoutingAutomationSession {
        RoutingAutomationSession(
            native : MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(TreeStub(tree)), workspace: WorkspaceStub(),
                                          leases: MacAppLeases()),
            desktop: desktop,
            web    : web
        )
    }

    @Test("the app's router: an address goes to the web session, a native app to the MacDriver, closing the web one")
    func appRouterWebThenNative() async throws {
        let desktop = SessionStub(handoff: nil)
        let web = SessionStub(handoff: nil)
        let routing = appRouter(Self.rich, desktop: desktop, web: web)

        _ = try await routing.open(application: "web:example.com", window: nil)
        _ = try await routing.observe()
        #expect(web.opened == ["web:example.com"] && web.observed == 1)
        #expect(routing.id == web.id)

        _ = try await routing.open(application: "Notes", window: nil)
        #expect(routing.lastHandoff == nil, "the MacDriver took Notes")
        #expect(routing.memoryApplication == Self.notes.bundleID)
        #expect(web.id == nil, "opening an app closed the web session")
        #expect(desktop.opened.isEmpty)
        await routing.close()
    }

    @Test("the app's router: a sparse window goes to the seat by bundle id with the MacDriver's reason")
    func appRouterSparse() async throws {
        let desktop = SessionStub(handoff: nil)
        let routing = appRouter(Self.sparse, desktop: desktop, web: SessionStub(handoff: nil))

        _ = try await routing.open(application: "Notes", window: nil)
        #expect(desktop.opened == [Self.notes.bundleID])
        let handoff = try #require(routing.lastHandoff as? MacHandoff)
        #expect(handoff.bundleID == Self.notes.bundleID)
        if case .sparse = handoff {} else { Issue.record("expected a sparse handoff, got \(handoff)") }
        #expect(routing.id == desktop.id)
    }

    // MARK: I03 and I02: one owner drives an app at a time

    /// A session of `owner` on its own fake rich window and workspace, sharing `leases`.
    private func leased(_ leases: MacAppLeases, owner: String) -> (MacAutomationSession, TreeStub, WorkspaceStub) {
        let reader = TreeStub(Self.rich), workspace = WorkspaceStub()
        return (MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(reader), workspace: workspace,
                                     leases: leases, leaseOwner: owner), reader, workspace)
    }

    @Test("I03: while one owner's session drives an app, another owner's is refused before anything reaches it, with no handoff to the seat; once closed, the app is free")
    func anotherOwnerIsRefused() async throws {
        let leases = MacAppLeases()
        let (first, firstTree, _) = leased(leases, owner: "worker-a")
        let (second, secondTree, secondWorkspace) = leased(leases, owner: "worker-b")
        _ = try await first.open(application: "Notes", window: nil)
        do {
            _ = try await second.open(application: "Notes", window: nil)
            Issue.record("a second owner opened the leased app")
        } catch let refusal as AutomationFailure {
            #expect(refusal.description.contains("being driven by another Braus worker or client"), "\(refusal)")
        } catch {
            Issue.record("refused otherwise than as contention (a handoff would reach the seat): \(error)")
        }
        #expect(second.id == nil)
        #expect(secondWorkspace.running.withLock { $0.isEmpty }, "the refused session launched nothing")
        #expect(secondTree.steps.withLock { $0.isEmpty }, "the refused session sent nothing")
        _ = try await first.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(firstTree.steps.withLock { $0 } == ["perform AXPress [3]"])
        await first.close()
        _ = try await second.open(application: "Notes", window: nil)
        #expect(second.id != nil, "the closed session gave the app back")
        await second.close()
    }

    @Test("I03: an open the MacDriver hands to the seat keeps the app claimed until the native session closes")
    func handedBackOpenKeepsTheClaimUntilClose() async throws {
        let leases = MacAppLeases()
        let sparse = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(TreeStub(Self.sparse)),
                                          workspace: WorkspaceStub(), leases: leases, leaseOwner: "worker-a")
        await #expect(throws: MacHandoff.self) { try await sparse.open(application: "Notes", window: nil) }
        let (other, _, otherWorkspace) = leased(leases, owner: "worker-b")
        await #expect(throws: AutomationFailure.self) { _ = try await other.open(application: "Notes", window: nil) }
        #expect(otherWorkspace.running.withLock { $0.isEmpty }, "no other owner takes the app during the handoff")
        await sparse.close()
        _ = try await other.open(application: "Notes", window: nil)
        #expect(other.id != nil)
        await other.close()
    }

    @Test("I03: one owner's sessions share an app, and one closing or going away never frees another's hold")
    func oneSessionClosingKeepsTheOthersHold() async throws {
        let leases = MacAppLeases()
        let (first, firstTree, _) = leased(leases, owner: "worker-a")
        var sameWorker: MacAutomationSession? = leased(leases, owner: "worker-a").0
        let (otherWorker, _, otherWorkspace) = leased(leases, owner: "worker-b")
        _ = try await first.open(application: "Notes", window: nil)
        _ = try await sameWorker?.open(application: "Notes", window: nil)
        await sameWorker?.close()
        sameWorker = nil
        await #expect(throws: AutomationFailure.self) {
            _ = try await otherWorker.open(application: "Notes", window: nil)
        }
        #expect(otherWorkspace.running.withLock { $0.isEmpty }, "the refused owner launched nothing")
        _ = try await first.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(firstTree.steps.withLock { $0 } == ["perform AXPress [3]"], "the first session still drives it")
        await first.close()
        _ = try await otherWorker.open(application: "Notes", window: nil)
        #expect(otherWorker.id != nil, "the last hold given back frees the app")
        await otherWorker.close()
    }

    @Test("I02: a worker's two conversations share its apps, but neither accepts the other's session by its ID, and a closed session's ID is not valid again")
    func conversationsKeepTheirSessions() async throws {
        let leases = MacAppLeases(), desktop = SessionStub(handoff: nil)
        func conversation() -> (AutomationTools, TreeStub) {
            let reader = TreeStub(Self.rich)
            let native = MacAutomationSession(knowledgeDirectory: knowledge(), roles: roles(reader),
                                              workspace: WorkspaceStub(), leases: leases, leaseOwner: "worker-a")
            return (AutomationTools(session: RoutingAutomationSession(native: native, desktop: desktop)), reader)
        }
        let (first, firstTree) = conversation()
        let (second, secondTree) = conversation()
        let opened = try answer(try await first.call("open_session", .object(["app": .string("Notes")])))
        let old = try #require(opened["session"].string)
        await #expect(throws: (any Error).self) {
            _ = try await second.call("act", .object(["session": .string(old), "target": .string("B3")]))
        }
        #expect(firstTree.steps.withLock { $0.isEmpty } && secondTree.steps.withLock { $0.isEmpty })
        #expect(desktop.opened.isEmpty, "nothing went to the seat")
        // Its own open of the same app is the same worker's: allowed, under its own ID.
        let own = try answer(try await second.call("open_session", .object(["app": .string("Notes")])))
        #expect(own["session"].string != nil && own["session"].string != old)
        // The first conversation closes its session and opens again: the old ID stays refused.
        _ = try await first.call("close_session", .object(["session": .string(old)]))
        let again = try answer(try await first.call("open_session", .object(["app": .string("Notes")])))
        #expect(again["session"].string != nil && again["session"].string != old)
        await #expect(throws: (any Error).self) {
            _ = try await first.call("act", .object(["session": .string(old), "target": .string("B3")]))
        }
        #expect(firstTree.steps.withLock { $0.isEmpty } && desktop.opened.isEmpty)
    }

    // MARK: The router before every session

    @Test("open_session asks the router first: a better route is answered, a named app is opened")
    func routerBeforeSession() async throws {
        let session = SessionStub(handoff: nil)
        session.id = nil
        let tools = AutomationTools(session: session, channels: .web)
        tools.adapters = AppAdapters([])

        let maps = try answer(await tools.call("open_session", .object(["app": .string("Maps")])))
        #expect(maps["opened"] == .bool(false))
        #expect(maps["route"].string == "web:google.com/maps")
        #expect(session.opened.isEmpty)

        let mail = try answer(await tools.call("open_session", .object(["app": .string("Mail")])))
        #expect(mail["session"].string != nil, "without a composed Mail adapter its interface opens")
        #expect(session.opened == ["Mail"])

        _ = try await tools.call("open_session", .object(["app": .string("Maps"), "named": .bool(true)]))
        #expect(session.opened == ["Mail", "Maps"])
    }

    @Test("R02: with the adapters and no web, open_session answers a ready adapter's route, opens a web-routed app as asked, and a named app as named")
    func adaptersWithoutTheWeb() async throws {
        let session = SessionStub(handoff: nil)
        session.id = nil
        let tools = AutomationTools(session: session, channels: .adapters)
        tools.adapters = AppAdapters([ReadyAdapter()])
        #expect(tools.router != nil, "the adapters are a route of their own")
        #expect(tools.instructions == AutomationTools.instructions(for: .adapters), "no web is served")

        let calendar = try answer(await tools.call("open_session", .object(["app": .string("Calendar")])))
        #expect(calendar["opened"] == .bool(false) && calendar["route"].string == "app_call(calendar)", "\(calendar)")
        #expect(session.opened.isEmpty)

        _ = try await tools.call("open_session", .object(["app": .string("Maps")]))
        #expect(session.opened == ["Maps"], "no web page can open here, so Maps opens as asked")
        await session.close()

        _ = try await tools.call("open_session", .object(["app": .string("Calendar"), "named": .bool(true)]))
        #expect(session.opened == ["Maps", "Calendar"], "the named app, not the adapter")
    }

    @Test("R02: each composition offers only its own routes: none, the web, the adapters, both; what it serves and advertises names no channel it lacks")
    func routesFollowTheComposition() async throws {
        func openSession(_ tools: AutomationTools) throws -> JSONValue {
            try #require(tools.toolDefinitions.first { $0["name"].string == "open_session" })
        }
        let cases: [(AutomationChannels, maps: String?, calendar: String?)] = [
            ([], nil, nil),
            (.web, "web:google.com/maps", nil),
            (.adapters, nil, "app_call(calendar)"),
            ([.web, .adapters], "web:google.com/maps", "app_call(calendar)"),
        ]
        for (channels, maps, calendar) in cases {
            let session = SessionStub(handoff: nil)
            session.id = nil
            let tools = AutomationTools(session: session, channels: channels)
            if channels.contains(.adapters) { tools.adapters = AppAdapters([ReadyAdapter()]) }
            let routed = !channels.isDisjoint(with: [.web, .adapters])
            #expect((tools.router != nil) == routed, "\(channels)")
            #expect(tools.instructions == AutomationTools.instructions(for: channels), "served = composed: \(channels)")
            #expect(tools.toolDefinitions == AutomationTools.definitions(for: channels), "\(channels)")
            let schema = try openSession(tools)
            #expect((schema["inputSchema"]["properties"]["named"] != .null) == routed, "\(channels)")
            let description = schema["description"].string ?? ""
            #expect(description.contains("a web page") == channels.contains(.web), "\(channels)")
            #expect(description.contains("an app_call adapter") == channels.contains(.adapters), "\(channels)")

            for (app, route) in [("Maps", maps), ("Calendar", calendar)] {
                let answered = try answer(await tools.call("open_session", .object(["app": .string(app)])))
                if let route {
                    #expect(answered["opened"] == .bool(false) && answered["route"].string == route,
                            "\(channels) \(app): \(answered)")
                } else {
                    #expect(session.opened.last == app, "\(channels) \(app) opens as asked: \(answered)")
                    await session.close()
                }
            }
        }
    }

    @Test("an adapter route points to app_call only when the adapter can run; otherwise the app opens with a note")
    func adapterRoute() async throws {
        let session = SessionStub(handoff: nil)
        session.id = nil
        let tools = AutomationTools(session: session, channels: .web)
        tools.adapters = AppAdapters([ReadyAdapter()])
        let calendar = try answer(await tools.call("open_session", .object(["app": .string("Calendar")])))
        #expect(calendar["opened"] == .bool(false))
        #expect(calendar["message"].string?.contains("app_call") == true)

        let finder = try answer(await tools.call("open_session", .object(["app": .string("Finder")])))
        #expect(session.opened == ["Finder"])
        #expect(finder["routeNote"].string?.contains("no files adapter") == true)
    }
}

// MARK: Doubles

/// One app installed, launched as pid 500; the person's app in front. A self-activating launch takes the
/// front; `restores` false keeps it there whatever is activated.
final class WorkspaceStub: MacWorkspace {
    let apps: [MacApp]
    let selfActivates: Bool
    let restores: Bool
    /// A self-activating launch comes forward with a dialog, which `revert` leaves in front.
    let dialog: Bool
    let front: Mutex<MacRunningApp?>
    let running = Mutex<[String: MacRunningApp]>([:])

    init(apps: [MacApp] = [MacSessionTests.notes], selfActivates: Bool = false, restores: Bool = true,
         dialog: Bool = false) {
        self.apps = apps
        self.selfActivates = selfActivates
        self.restores = restores
        self.dialog = dialog
        front = Mutex(MacSessionTests.person)
    }

    func installedApplications() -> [MacApp] { apps }
    func application(bundleID: String) -> MacApp? { apps.first { $0.bundleID == bundleID } }
    func application(at url: URL) -> MacApp? { nil }
    func running(bundleID: String) -> MacRunningApp? { running.withLock { $0[bundleID] } }
    func frontmost() async -> MacRunningApp? { front.withLock { $0 } }
    func launch(_ app: MacApp) async throws -> MacRunningApp {
        let process = MacRunningApp(processID: MacSessionTests.pid, bundleID: app.bundleID, name: app.displayName)
        running.withLock { $0[app.bundleID] = process }
        if selfActivates { front.withLock { $0 = process } }
        return process
    }
    func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp { try await launch(app) }
    func openLink(_ link: URL) async throws {}
    func defaultApplication(for item: URL) -> MacApp? { nil }
    func activate(_ processID: pid_t) async {
        guard restores else { return }
        front.withLock { $0 = MacRunningApp(processID: processID) }
    }
    func secondsSincePersonInput() -> TimeInterval { 600 }
    func takeSparedDialog(of bundleID: String) -> Bool { selfActivates && dialog }
}

/// One window for every process; records the accessibility steps sent. Pressing a control named in
/// `pressed` replaces the window with the tree given for it, the effect the app shows.
final class TreeStub: MacTreeReading, MacAccessibilityActing {
    let current: Mutex<MacTreeNode>
    let pressed: [String: MacTreeNode]
    let steps = Mutex<[String]>([])
    let isTrusted = true
    /// What a press does besides its effect on the tree, such as the app activating itself.
    let onPerform: (@Sendable () -> Void)?

    init(_ tree: MacTreeNode, pressed: [String: MacTreeNode] = [:], onPerform: (@Sendable () -> Void)? = nil) {
        current        = Mutex(tree.addressed())
        self.pressed   = pressed.mapValues { $0.addressed() }
        self.onPerform = onPerform
    }

    var tree: MacTreeNode { current.withLock { $0 } }

    func windows(of processID: pid_t) throws -> [MacWindowSummary] {
        [MacWindowSummary(index: 0, role: "AXWindow", title: tree.title, frame: tree.frame, isMain: true, isFocused: true)]
    }
    func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) throws -> MacTreeRead {
        let tree = tree
        return MacTreeRead(window: tree, nodesVisited: tree.flattened.count)
    }
    func perform(_ action: String, on element: MacElementAddress) throws {
        steps.withLock { $0.append("perform \(action) \(element.path)") }
        let title = tree.flattened.first { $0.path == element.path }?.title
        if let title, let effect = pressed[title] { current.withLock { $0 = effect } }
        onPerform?()
    }
    func select(_ element: MacElementAddress) throws { steps.withLock { $0.append("select \(element.path)") } }
    func focus(_ element: MacElementAddress) throws { steps.withLock { $0.append("focus \(element.path)") } }
    func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) throws -> String { "bar" }
    func readBack(_ element: MacElementAddress) -> MacTreeNode? { nil }
}

struct NoDelivery: MacEventDelivering {
    /// Whether the key-window records stay applied after a key gesture.
    var leavesPreparation = false

    func deliver(
        _ gesture     : Gesture,
        toWindow windowNumber: Int,
        of processID  : pid_t,
        needsKeyWindow: Bool
    ) async throws -> MacEventReceipt {
        MacEventReceipt(preparationNotRestored: leavesPreparation && needsKeyWindow)
    }
}

struct QuietNotifications: MacNotificationSource {
    func watch(_ processID: pid_t) {}
    func lastNotification(of processID: pid_t) -> ContinuousClock.Instant? { nil }
}

struct NoControls: ControlPressing {
    func pressControl(labelled label: String, in processID: pid_t) async -> Bool { false }
    func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool { false }
    func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? { nil }
    func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { nil }
    func focusedFieldValue(in processID: pid_t) async -> String? { nil }
}

/// Controls whose press makes the app activate itself, and presses nothing in the tree.
struct ActivatingControls: ControlPressing {
    let activate: @Sendable () -> Void
    func pressControl(labelled label: String, in processID: pid_t) async -> Bool { activate(); return false }
    func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool { false }
    func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? { nil }
    func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { nil }
    func focusedFieldValue(in processID: pid_t) async -> String? { nil }
}

/// No touch at its first answers, then a touch at the moment of asking from the `from`-th question on: a person
/// whose touch shows up only at a later check.
final class TouchFrom: MacPersonWatching, @unchecked Sendable {
    let from: Int
    let asked = Mutex<Int>(0)
    init(_ from: Int) { self.from = from }
    var isWatching: Bool { true }
    func lastTouch(of processID: pid_t) -> ContinuousClock.Instant? {
        asked.withLock { count in
            count += 1
            return count >= from ? .now : nil
        }
    }
}

/// The census with a menu open over the window: its menu-layer window, in front of the window.
struct MenuOpen: WindowListing {
    func windows(ownedBy processID: pid_t) async throws -> [WindowRow] {
        [WindowRow(layer: 101, frame: CGRect(x: 0, y: 0, width: 220, height: 240), title: nil, number: 9),
         WindowRow(layer: 0, frame: MacSessionTests.frame, title: "Export", number: 7)]
    }
}

/// Counts the menu presses delegated to it, each answered as made.
final class CountingMenus: ControlPressing, @unchecked Sendable {
    let presses = Mutex<Int>(0)
    func pressControl(labelled label: String, in processID: pid_t) async -> Bool { false }
    func controlValue(matchingAny labels: Set<String>, in processID: pid_t) async -> String? { nil }
    func toggleState(at point: CGPoint, in processID: pid_t) async -> ControlState? { nil }
    func focusedFieldValue(in processID: pid_t) async -> String? { nil }
    func pressMenuItem(titled title: String, within menuFrame: CGRect, in processID: pid_t) async -> Bool {
        presses.withLock { $0 += 1 }
        return true
    }
}

/// Counts the events delivered to the app.
final class CountingDelivery: MacEventDelivering, @unchecked Sendable {
    let events = Mutex<Int>(0)
    func deliver(_ gesture: Gesture, toWindow windowNumber: Int, of processID: pid_t, needsKeyWindow: Bool) async throws -> MacEventReceipt {
        events.withLock { $0 += 1 }
        return MacEventReceipt(preparationNotRestored: false)
    }
}

/// The person touches every app all the time: every scene is older than their last input.
struct AlwaysTouched: MacPersonWatching {
    var isWatching: Bool { true }
    func lastTouch(of processID: pid_t) -> ContinuousClock.Instant? { .now }
}

/// A calendar adapter that is ready and has no verbs.
struct ReadyAdapter: AppAdapting {
    var name: String { "calendar" }
    var appNames: [String] { ["Calendar"] }
    var bundleIDs: Set<String> { ["com.apple.iCal"] }
    var verbs: [AdapterVerb] { [] }
    func availability() async -> AdapterAvailability { .ready }
    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        AdapterOutcome(.refused, "no verbs")
    }
}

/// A session that records what it opened and gives `handoff` back when it has one.
@MainActor
final class SessionStub: AutomationSessionOperating {
    let handoff: MacHandoff?
    var id: UUID? = nil
    var opened: [String] = []
    var observed = 0

    init(handoff: MacHandoff?) { self.handoff = handoff }

    static let scene = SceneSnapshot(bundleID: "com.example", appName: "Example", windowTitle: "Example",
                                     viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: [])

    func resolvedBundleID(of application: String) async -> String? {
        ["Calendar": "com.apple.iCal", "Calendario": "com.apple.iCal", "Maps": "com.apple.Maps",
         "Mail": "com.apple.mail", "Finder": "com.apple.finder", "Notes": "com.apple.Notes"][application]
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        if let handoff { throw handoff }
        opened.append(application)
        id = UUID()
        return Self.scene
    }
    func observe() async throws -> SceneSnapshot { observed += 1; return Self.scene }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        ActOutcome(.refused, "stub")
    }
    func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.refused, "stub") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { ActOutcome(.refused, "stub") }
    func close() async { id = nil }
    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] { [] }
}
