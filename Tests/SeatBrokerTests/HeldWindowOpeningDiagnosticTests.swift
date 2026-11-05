import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SeatDriving
import SeatSession
@testable import SeatBroker
import Testing

/// The held Broker.open transition and its production exact-selection guard, with window enumeration faked.
@MainActor
@Suite(.serialized)
struct HeldWindowOpeningDiagnosticTests {
    @Test(arguments: [0, 2])
    func missingOrDuplicateHeldTitlesPreserveTheSessionAndMinimizeFacts(_ matches: Int) async throws {
        let f = HeldSelectionFixture(matches: matches)
        _ = try await f.call("open_session", ["app": .string(f.privateApp)])
        let original = f.session.id
        let entries = f.broker.queue.entries
        let plan = try await f.call("plan", ["request": .string("Inspect held selection"),
            "rows": .array([.object(["title": .string("Inspect the requested window")])]),
            "inputs": .array([f.privateApp, f.privateTitle].enumerated().map { index, value in
                .object(["name": .string("private_\(index)"), "value": .string(value), "secret": .bool(true)])
            })])
        #expect(plan["isError"].bool != true)
        let response = try await f.call("open_session", ["app": .string(f.privateApp), "window": .string(f.privateTitle)])
        let text = f.text(response)
        #expect(response["isError"].bool == true)
        #expect(text.contains("exact window title") && text.contains("(\(matches) matches)"))
        #expect(text.contains("uncertain") && !text.contains("not_sent"))
        #expect(text.contains("previous application session is still active"))
        #expect(!text.contains("may already have launched or reopened"))
        #expect(!text.contains("The held window was not changed"))
        #expect(text.contains("preceding observation may already have changed"))
        #expect(!text.contains(f.privateApp) && !text.contains(f.privateTitle))
        let captured = f.failure
        let failure = try #require(captured)
        #expect(failure.state == .previousRetained && failure.causeCode == "opening_window_title_mismatch")
        #expect(!failure.isBeforeApplicationLaunch)
        #expect(f.session.id == original && f.session.memoryApplication == "test.held")
        #expect(f.broker.queue.entries == entries && f.openings == 1 && f.switches == 0)
        let observed = try await f.call("observe", ["full": .bool(true)])
        #expect(observed["isError"].bool != true && f.session.id == original)
        try await f.close()
    }

    @Test func heldSelectionKeepsCaseSensitiveMatchingAndTheUniquePositiveControl() throws {
        let window = TargetWindow(pid: 601, windowNumber: 701, title: "Exact.txt", frame: .zero)
        #expect(try BrokeredAutomationSession.exactHeldWindow(in: [window], title: "Exact.txt", application: "Public").windowNumber == 701)
        do {
            _ = try BrokeredAutomationSession.exactHeldWindow(in: [window], title: "EXACT.TXT", application: "Public")
            Issue.record("Held matching must remain case sensitive")
        } catch let failure as ApplicationOpeningFailure {
            guard case .windowTitleMismatch(let selection)? = failure.reason else {
                Issue.record("Missing selection facts")
                return
            }
            #expect(selection.matches == 0 && selection.available == ["Exact.txt"])
        }
    }
}

@MainActor
private final class HeldSelectionFixture {
    private final class Running: NSRunningApplication {
        override var isTerminated: Bool { false }
        override var bundleIdentifier: String? { "test.held" }
        override var localizedName: String? { "NR01_HELD_PRIVATE_APP" }
        override var processIdentifier: pid_t { 601 }
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "nr01-held-\(UUID())")
    let privateApp = "NR01_HELD_PRIVATE_APP"
    let privateTitle = "NR01_HELD_PRIVATE_TITLE"
    let matches: Int
    var openings = 0
    var switches = 0
    var failure: ApplicationOpeningFailure?
    var sequence = 0
    lazy var broker = SeatBroker(configuration: .init(perceptionStoreDirectory: root.appending(path: "Perception"),
        recordingDirectory: root.appending(path: "Runs")))
    lazy var session = BrokeredAutomationSession(broker: broker, workerID: UUID(), knowledgeDirectory: root,
        allowsDestructive: false, claims: AppClaims(), resolving: { _ in "test.held" }, missingGrant: { nil },
        requestGrants: {}, seating: { [unowned self] _, _, _ in
            openings += 1
            return (TargetApp(pid: 601, bundleID: "test.held", name: privateApp, bundleURL: nil, windows: []), SeatTarget())
        }, perceiving: { _, _ in
            SceneSnapshot(bundleID: "test.held", appName: "Public", windowTitle: "Public held window",
                viewportPixelSize: .init(width: 100, height: 100), elements: [])
        }, runningApplication: { _ in Running() }, switching: { [unowned self] _, _, title, application in
            let titles = matches == 0 ? ["Other.txt"] : Array(repeating: privateTitle, count: matches)
            let windows = titles.enumerated().map { index, title in
                TargetWindow(pid: 601, windowNumber: 701 + index, title: title, frame: .zero)
            }
            do {
                _ = try BrokeredAutomationSession.exactHeldWindow(in: windows, title: title, application: application)
                switches += 1
            } catch let error as ApplicationOpeningFailure { failure = error; throw error }
        }, stoppedForGood: { _ in false })
    lazy var tools = AutomationTools(session: session)
    lazy var router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)

    init(matches: Int) { self.matches = matches }

    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        sequence += 1
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
            "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])
        let answer = try #require(await router.handle(request))
        #expect(answer["error"] == .null)
        return answer["result"]
    }

    func text(_ result: JSONValue) -> String {
        result["content"].array?.compactMap { $0["text"].string }.joined(separator: "\n") ?? ""
    }

    func close() async throws {
        await session.close()
        let memory = MemoryService.shared(for: root)
        await memory.close()
        MemoryService.forget(root)
        try FileManager.default.removeItem(at: root)
    }
}
