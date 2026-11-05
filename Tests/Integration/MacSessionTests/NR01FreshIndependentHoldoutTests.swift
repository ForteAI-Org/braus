import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import MacDriver
import MacDriving
import MacSession
import Memory
import PerceptionCore
import Synchronization
import Testing

/// Fresh independent stage-negative case. Do not disclose before implementation FREEZE2.
@MainActor
struct NR01FreshIndependentHoldoutTests {
    @Test
    func ambiguityReportedInsideLaunchStaysUncertainAndKeepsA() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nr01-fresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bID = "org.nr01.stage.actual-b"
        let privateValues = ["NR01_PRIVATE_LATE_ALIAS", "org.nr01.private.late.one", "org.nr01.private.late.two"]
        let b = MacApp(bundleID: bID, url: URL(fileURLWithPath: "/Applications/NR01LateB.app"), names: ["Public B"])
        let base = WorkspaceStub(apps: [MacSessionTests.notes, b], processIDs: [bID: 501])
        let workspace = LateStageWorkspace(base: base, target: bID, privateValues: privateValues)
        var bTree = MacSessionTests.rich
        bTree.title = "Public B window"
        let reader = TreeStub(MacSessionTests.rich, trees: [501: bTree])
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
            notifications: QuietNotifications(), controls: NoControls(),
            serverWindows: { pid in [(number: Int(pid) + 700, frame: MacSessionTests.frame)] },
            identity: { pid in pid == 501 ? (bID, "Public B") : (MacSessionTests.notes.bundleID, "Notes") })
        let native = MacAutomationSession(knowledgeDirectory: root, roles: roles,
            workspace: workspace, leases: MacAppLeases())
        let session = FreshCapturedSession(native)
        let tools = AutomationTools(session: session, channels: [.native])
        let transcript = FreshTranscript()
        tools.record = { transcript.lines.append($0) }
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        var sequence = 0
        var stopped = false
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            sequence += 1
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
                "method": .string("tools/call"), "params": .object(["name": .string(name),
                    "arguments": .object(arguments)])])
            let answer = try #require(await router.handle(request))
            #expect(answer["error"] == .null)
            return answer["result"]
        }
        func text(_ value: JSONValue) -> String {
            value["content"].array?.compactMap { $0["text"].string }.joined(separator: "\n") ?? ""
        }
        func stop() async {
            guard !stopped else { return }
            stopped = true
            tools.record = nil
            await session.close()
            let memory = MemoryService.shared(for: root)
            await memory.close()
            MemoryService.forget(root)
        }
        do {
            let opened = try await call("open_session", ["app": .string("Notes")])
            #expect(opened["isError"].bool != true)
            let original = try #require(native.id)
            let plan = try await call("plan", ["request": .string("Inspect a later opening failure"),
                "rows": .array([.object(["title": .string("Inspect the requested application")])]),
                "inputs": .array(privateValues.enumerated().map { index, value in
                    .object(["name": .string("private\(index)"), "value": .string(value), "secret": .bool(true)])
                })])
            #expect(plan["isError"].bool != true)
            let running = base.running.withLock { Set($0.keys) }
            let front = await base.frontmost()?.processID
            let actions = reader.steps.withLock { $0 }
            let refused = try await call("open_session", ["app": .string(bID)])
            #expect(refused["isError"].bool == true)
            let message = text(refused)
            #expect(message.contains("uncertain") && !message.contains("not_sent"))
            #expect(!message.contains("No application launch was requested"))
            #expect(workspace.attempts.withLock { $0 } == 1, "This was inside the genuine launch call, not failed resolution")
            if let typed = session.lastOpeningError as? ApplicationOpeningFailure {
                #expect(!typed.isBeforeApplicationLaunch, "A matching error type does not attest the earlier stage")
            }
            #expect(native.id == original && native.memoryApplication == MacSessionTests.notes.bundleID)
            #expect(base.running.withLock { Set($0.keys) } == running && base.running(bundleID: bID) == nil)
            #expect(await base.frontmost()?.processID == front)
            #expect(reader.steps.withLock { $0 } == actions)
            for value in privateValues {
                #expect(!message.contains(value))
                #expect(!transcript.lines.joined(separator: "\n").contains(value))
            }
            #expect(!message.contains("MacLaunchFailure(") && !message.contains("AutomationFailure("))
            let observed = try await call("observe", ["full": .bool(true)])
            #expect(observed["isError"].bool != true && text(observed).contains("Notes"))
            #expect(native.id == original && workspace.attempts.withLock { $0 } == 1)
            // Explicitly correct the simulated lower condition, then select the exact installed identity.
            workspace.fail.withLock { $0 = false }
            let recovered = try await call("open_session", ["app": .string(bID)])
            #expect(recovered["isError"].bool != true && native.memoryApplication == bID)
            #expect(workspace.attempts.withLock { $0 } == 2 && base.running(bundleID: bID) != nil)
            #expect(reader.steps.withLock { $0 } == actions)
            await stop()
            try assertFreshArchiveHasNoPrivateValues(root: root, values: privateValues)
        } catch {
            await stop()
            throw error
        }
    }
}

private final class LateStageWorkspace: MacWorkspace {
    let base: WorkspaceStub
    let target: String
    let privateValues: [String]
    let attempts = Mutex(0)
    let fail = Mutex(true)
    init(base: WorkspaceStub, target: String, privateValues: [String]) {
        self.base = base; self.target = target; self.privateValues = privateValues
    }
    func installedApplications() -> [MacApp] { base.installedApplications() }
    func application(bundleID: String) -> MacApp? { base.application(bundleID: bundleID) }
    func application(at url: URL) -> MacApp? { base.application(at: url) }
    func running(bundleID: String) -> MacRunningApp? { base.running(bundleID: bundleID) }
    func frontmost() async -> MacRunningApp? { await base.frontmost() }
    func launch(_ app: MacApp) async throws -> MacRunningApp {
        if app.bundleID == target {
            attempts.withLock { $0 += 1 }
            if fail.withLock({ $0 }) { throw MacLaunchFailure.ambiguous(privateValues[0], Array(privateValues.dropFirst())) }
        }
        return try await base.launch(app)
    }
    func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp { try await launch(app) }
    func openLink(_ link: URL) async throws {}
    func defaultApplication(for item: URL) -> MacApp? { nil }
    func activate(_ processID: pid_t) async { await base.activate(processID) }
    func secondsSincePersonInput() -> TimeInterval { 600 }
}

@MainActor
private final class FreshTranscript { var lines: [String] = [] }

@MainActor
private final class FreshCapturedSession: AutomationSessionOperating {
    let native: MacAutomationSession
    var lastOpeningError: (any Error)?
    init(_ native: MacAutomationSession) { self.native = native }
    var id: UUID? { native.id }
    var memoryApplication: String? { native.memoryApplication }
    var memoryDirectory: URL? { native.memoryDirectory }
    func resolvedBundleID(of application: String) async -> String? { await native.resolvedBundleID(of: application) }
    func open(application: String, window: String?) async throws -> SceneSnapshot {
        do { return try await native.open(application: application, window: window) }
        catch { lastOpeningError = error; throw error }
    }
    func observe() async throws -> SceneSnapshot { try await native.observe() }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        try await native.act(target: target, verb: verb, section: section, desiredState: desiredState)
    }
    func select(control: String, item: String) async throws -> ActOutcome { try await native.select(control: control, item: item) }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { try await native.deliver(input, section: section) }
    func close() async { await native.close() }
}

/// DirectoryEnumerator's iterator is unavailable from async contexts; the oracle stays synchronous.
private func assertFreshArchiveHasNoPrivateValues(root: URL, values: [String]) throws {
    if let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let file as URL in paths where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = try Data(contentsOf: file)
            for value in values { #expect(data.range(of: Data(value.utf8)) == nil, "Private late-error data in \(file.lastPathComponent)") }
        }
    }
}
