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

/// Independent case preregistered before the NR01 implementation draft was disclosed.
/// Installed-name ambiguity is neither a missing application nor a window-title mismatch.
@MainActor
struct NR01IndependentHoldoutTests {
    @Test
    func ambiguousInstalledNamePreservesAAndDoesNotLeakCandidates() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "nr01-heldout-\(UUID())")
        let privateAlias = "NR01_PRIVATE_ALIAS_CANARY"
        let firstID = "org.nr01.private.candidate.one"
        let secondID = "org.nr01.private.candidate.two"
        let first = MacApp(bundleID: firstID, url: URL(fileURLWithPath: "/Applications/NR01First.app"), names: [privateAlias])
        let second = MacApp(bundleID: secondID, url: URL(fileURLWithPath: "/Applications/NR01Second.app"), names: [privateAlias])
        let workspace = WorkspaceStub(apps: [MacSessionTests.notes, first, second], processIDs: [firstID: 501, secondID: 502])
        var firstTree = MacSessionTests.rich
        firstTree.title = "Selected first candidate"
        let reader = TreeStub(MacSessionTests.rich, trees: [501: firstTree])
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
            notifications: QuietNotifications(), controls: NoControls(),
            serverWindows: { pid in [(number: Int(pid) + 700, frame: MacSessionTests.frame)] },
            identity: { pid in
                pid == 501 ? (firstID, "First") : (MacSessionTests.notes.bundleID, "Notes")
            })
        let native = MacAutomationSession(knowledgeDirectory: directory, roles: roles,
            workspace: workspace, leases: MacAppLeases())
        let session = CapturedNativeSession(native)
        let tools = AutomationTools(session: session, channels: [.native])
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        var requestID = 0
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            requestID += 1
            let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(requestID)),
                "method": .string("tools/call"), "params": .object(["name": .string(name),
                    "arguments": .object(arguments)])])
            let answer = try #require(await router.handle(request))
            #expect(answer["error"] == .null, "A tool refusal belongs in the real MCP result, not an RPC error")
            return answer["result"]
        }
        func text(_ result: JSONValue) throws -> String {
            try #require(result["content"].array).compactMap { $0["text"].string }.joined(separator: "\n")
        }
        func close() async {
            await session.close()
            let memory = MemoryService.shared(for: directory)
            await memory.close()
            MemoryService.forget(directory)
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let initial = try await call("open_session", ["app": .string("Notes")])
            #expect(initial["isError"].bool != true)
            let originalID = try #require(native.id)
            // Declare all private sentinels through the real task parser/minimization path.
            let plan = try await call("plan", ["request": .string("Inspect application availability"),
                "rows": .array([.object(["title": .string("Inspect the requested application")])]),
                "inputs": .array([privateAlias, firstID, secondID].enumerated().map { index, value in
                    .object(["name": .string("private_input_\(index)"), "value": .string(value), "secret": .bool(true)])
                })])
            #expect(plan["isError"].bool != true)
            let beforeRunning = workspace.running.withLock { Set($0.keys) }
            let beforeFront = await workspace.frontmost()?.processID
            let beforeActions = reader.steps.withLock { $0 }
            let failure = try await call("open_session", ["app": .string(privateAlias)])
            #expect(failure["isError"].bool == true)
            let message = try text(failure)
            #expect(message.contains("not_sent · not_applicable"), "Native resolution did not request a launch")
            #expect(!message.contains("The call ended before its effect could be read."),
                "A known installed-name ambiguity must not collapse to the generic late-read error")
            if let cause = session.lastOpeningError as? ApplicationOpeningFailure {
                #expect(cause.reason != nil, "A state alone does not preserve the ambiguity reason")
                #expect(cause.causeCode != "opening_application_not_found")
                #expect(cause.causeCode != "opening_window_title_mismatch")
                #expect(message.contains(ModelText.openingFailure(cause,
                    minimization: .init(secrets: [privateAlias, firstID, secondID]))))
            } else {
                Issue.record("The real native producer did not transport installed-name ambiguity as a typed opening cause")
            }
            for secret in [privateAlias, firstID, secondID] {
                #expect(!message.contains(secret), "Private resolver data escaped the real MCP boundary")
            }
            #expect(!message.contains("MacLaunchFailure(") && !message.contains("AutomationFailure("))
            #expect(native.id == originalID && native.memoryApplication == MacSessionTests.notes.bundleID)
            #expect(workspace.running.withLock { Set($0.keys) } == beforeRunning)
            #expect(await workspace.frontmost()?.processID == beforeFront)
            #expect(reader.steps.withLock { $0 } == beforeActions)
            let observed = try await call("observe", ["full": .bool(true)])
            #expect(observed["isError"].bool != true)
            #expect(native.id == originalID && native.memoryApplication == MacSessionTests.notes.bundleID)
            #expect(try text(observed).contains("Notes"))
            // Neighbor control: the precise identity resolves the ambiguity without a permanent block.
            let selected = try await call("open_session", ["app": .string(firstID)])
            #expect(selected["isError"].bool != true)
            #expect(native.memoryApplication == firstID && native.id != nil)
            #expect(workspace.running(bundleID: firstID) != nil && workspace.running(bundleID: secondID) == nil)
            #expect(reader.steps.withLock { $0 } == beforeActions)
            await close()
        } catch {
            await close()
            throw error
        }
    }
}

/// Captures the real lower producer error without inventing or injecting one at the session boundary.
@MainActor
private final class CapturedNativeSession: AutomationSessionOperating {
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
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await native.deliver(input, section: section)
    }
    func close() async { await native.close() }
}
