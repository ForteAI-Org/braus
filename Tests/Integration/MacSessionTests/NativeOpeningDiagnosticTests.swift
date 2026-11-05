import AppKit
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
import Router
import SeatDriving
import SeatSession
@testable import SeatBroker
import Synchronization
import Testing

/// Real lookup, handoff, broker, opening selection and MCP schema; platform effects alone are fake.
@MainActor
@Suite(.serialized)
struct NativeOpeningDiagnosticTests {
    @Test(arguments: [false, true])
    func missingInstalledApplicationPreservesCauseAndKnownNoLaunch(_ retained: Bool) async throws {
        let f = NativeDiagnosticFixture()
        if retained { _ = try await f.call("open_session", ["app": .string("test.a")]) }
        let previous = f.routing.id
        let response = try await f.call("open_session", ["app": .string("Public missing application")])
        let text = f.text(response)
        #expect(response["isError"].bool == true)
        #expect(text.contains("No installed application"))
        #expect(text.contains("not_sent") && !text.contains("uncertain"))
        #expect(text.contains("previous application session is still active") == retained)
        #expect(f.routing.id == previous)
        #expect(f.workspace.running.withLock { $0.count } == (retained ? 1 : 0))
        #expect(f.seatLaunches.isEmpty && f.adopted.isEmpty)
        try await f.close()
    }

    @Test(arguments: [false, true], [2, 3])
    func ambiguousInstalledApplicationsRefuseBeforeLaunch(_ retained: Bool, _ matches: Int) async throws {
        let f = NativeDiagnosticFixture(candidates: matches)
        if retained { _ = try await f.call("open_session", ["app": .string("test.a")]) }
        let previous = f.routing.id
        let response = try await f.call("open_session", ["app": .string("Public app")])
        let text = f.text(response)
        #expect(response["isError"].bool == true)
        #expect(text.contains("matches \(matches) installed applications"))
        #expect(text.contains("not_sent · not_applicable") && !text.contains("uncertain"))
        #expect(!text.contains("test.b"))
        #expect(f.routing.id == previous)
        #expect(f.workspace.running.withLock { $0.count } == (retained ? 1 : 0))
        #expect(f.seatLaunches.isEmpty && f.adopted.isEmpty && f.quitRequests.isEmpty)
        do {
            _ = try await f.native.open(application: "Public app", window: nil)
            Issue.record("Ambiguous identity unexpectedly opened")
        } catch let failure as ApplicationOpeningFailure {
            guard case .applicationAmbiguous(let requested, let count)? = failure.reason else {
                Issue.record("Missing structured ambiguity facts")
                try await f.close()
                return
            }
            #expect(requested == "Public app" && count == matches)
            #expect(failure.isBeforeApplicationLaunch)
        }
        try await f.close()
    }

    @Test(arguments: [false, true])
    func nativeOtherWindowHandoffRetainsTheExactSelectionCause(_ retained: Bool) async throws {
        let f = NativeDiagnosticFixture()
        if retained { _ = try await f.call("open_session", ["app": .string("test.a")]) }
        let previous = f.routing.id
        let response = try await f.call("open_session", ["app": .string("test.b"), "window": .string("Public A")])
        let text = f.text(response)
        #expect(response["isError"].bool == true)
        #expect(text.contains("exact window title"))
        #expect(text.contains("Public A.txt") && text.contains("Public B.txt"))
        #expect(text.contains("uncertain") && !text.contains("not_sent"))
        #expect(text.contains("previous application session is still active") == retained)
        #expect(f.routing.id == previous)
        #expect(f.seatLaunches == ["test.b"] && f.adopted.isEmpty && f.quitRequests.isEmpty)
        #expect(f.broker.queue.entries.isEmpty)
        try await f.close()
    }

    @Test(arguments: [0, 2])
    func zeroAndDuplicateExactMatchesAreDistinctRefusals(_ matches: Int) async throws {
        let titles = matches == 0 ? ["Public A.txt", "Public B.txt"] : ["Twin.txt", "Twin.txt"]
        let wanted = matches == 0 ? "Public A" : "Twin.txt"
        let f = NativeDiagnosticFixture(available: titles)
        _ = try await f.call("open_session", ["app": .string("test.a")])
        let original = f.routing.id
        let response = try await f.call("open_session", ["app": .string("test.b"), "window": .string(wanted)])
        #expect(response["isError"].bool == true)
        #expect(f.text(response).contains("(\(matches) matches)"))
        #expect(f.routing.id == original && f.adopted.isEmpty && f.quitRequests.isEmpty)
        try await f.close()
    }

    @Test func anExactCaseInsensitiveTitleStillAdoptsOnce() async throws {
        let f = NativeDiagnosticFixture()
        let response = try await f.call("open_session", ["app": .string("test.b"), "window": .string("PUBLIC A.TXT")])
        #expect(response["isError"].bool != true)
        #expect(f.routing.id != nil && f.adopted == [602] && f.quitRequests.isEmpty)
        #expect(f.text(response).contains("Public A.txt"))
        try await f.close()
    }

    @Test(arguments: [false, true])
    func aNewlyLaunchedUnmatchedAppKeepsQuitAcceptanceSeparateFromExit(_ accepted: Bool) async throws {
        let f = NativeDiagnosticFixture()
        f.nativeEnabled = false
        f.bWasRunning = false
        f.quitAccepted = accepted
        let response = try await f.call("open_session", ["app": .string("test.b"), "window": .string("Public A")])
        let text = f.text(response)
        #expect(response["isError"].bool == true && text.contains("uncertain"))
        #expect(f.quitRequests == [602] && f.adopted.isEmpty && f.routing.id == nil)
        #expect(text.contains("was asked to quit; its exit was not verified") == accepted)
        #expect(text.contains("quit request for Public app was not confirmed") == !accepted)
        #expect(f.broker.queue.entries.isEmpty)
        try await f.close()
    }

    @Test func cancellationAfterLaunchKeepsItsTypeAfterOwnedCleanup() async throws {
        let f = NativeDiagnosticFixture()
        f.bWasRunning = false
        f.cancelAfterLaunch = true
        let opening = Task { try await f.desktop.open(application: "test.b", window: "Public A") }
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(f.quitRequests == [602] && f.adopted.isEmpty && f.desktop.id == nil)
        #expect(f.broker.queue.entries.isEmpty)
        try await f.close()
    }

    @Test(arguments: [false, true])
    func theSameErrorTypeDuringLaunchDoesNotClaimKnownNoDispatch(_ ambiguous: Bool) async throws {
        let failure: MacLaunchFailure = ambiguous ? .ambiguous("Public app", ["test.b", "test.c"]) : .notFound("Public app")
        let f = NativeDiagnosticFixture(lateFailure: failure)
        let response = try await f.call("open_session", ["app": .string("test.b")])
        #expect(response["isError"].bool == true)
        #expect(f.text(response).contains("uncertain") && !f.text(response).contains("not_sent"))
        #expect(f.lateLaunchAttempts == 1)
        try await f.close()
    }

    @Test func secretNamesAndWindowTitlesStayOutOfPayloadTranscriptAndArchive() async throws {
        let secrets = ["PRIVATE_MISSING_APP_CANARY", "PRIVATE_APP_CANARY", "PRIVATE_TITLE_CANARY"]
        let f = NativeDiagnosticFixture(bName: secrets[1], available: [secrets[2] + ".txt", "Public B.txt"])
        f.workspace.running.withLock { $0["test.b"] = MacRunningApp(processID: 501, bundleID: "test.b", name: secrets[1]) }
        _ = try await f.call("open_session", ["app": .string("test.a")])
        let inputs: [JSONValue] = secrets.enumerated().map { index, value in
            .object(["name": .string("private\(index)"), "value": .string(value), "secret": .bool(true)])
        }
        let plan = try await f.call("plan", ["request": .string("Inspect refused opening"),
            "rows": .array([.object(["title": .string("Inspect refused opening")])]), "inputs": .array(inputs)])
        #expect(plan["isError"].bool != true)
        let missing = try await f.call("open_session", ["app": .string(secrets[0])])
        let mismatch = try await f.call("open_session", ["app": .string("test.b"), "window": .string(secrets[2])])
        let payload = try JSONEncoder().encode([missing, mismatch])
        let transcript = f.lines.joined(separator: "\n")
        #expect(f.text(missing).contains("No installed application"))
        #expect(f.text(mismatch).contains("exact window title"))
        for secret in secrets {
            #expect(!String(decoding: payload, as: UTF8.self).contains(secret))
            #expect(!transcript.contains(secret))
        }
        let memory = MemoryService.shared(for: f.root)
        await memory.close()
        try f.assertNoPrivateArchiveValues(secrets)
        try await f.close()
    }
}

@MainActor
private final class NativeDiagnosticFixture {
    private final class Running: NSRunningApplication {
        override var bundleIdentifier: String? { "test.b" }
        override var localizedName: String? { "Public app" }
        override var processIdentifier: pid_t { 602 }
        override var isTerminated: Bool { false }
    }

    private final class RefusingLaunch: MacWorkspace {
        let base: WorkspaceStub
        let attempts = Mutex(0)
        let failure: MacLaunchFailure
        init(base: WorkspaceStub, failure: MacLaunchFailure) { self.base = base; self.failure = failure }
        func installedApplications() -> [MacApp] { base.installedApplications() }
        func application(bundleID: String) -> MacApp? { base.application(bundleID: bundleID) }
        func application(at url: URL) -> MacApp? { base.application(at: url) }
        func running(bundleID: String) -> MacRunningApp? { base.running(bundleID: bundleID) }
        func frontmost() async -> MacRunningApp? { await base.frontmost() }
        func launch(_ app: MacApp) async throws -> MacRunningApp {
            attempts.withLock { $0 += 1 }
            throw failure
        }
        func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp { try await launch(app) }
        func openLink(_ link: URL) async throws {}
        func defaultApplication(for item: URL) -> MacApp? { nil }
        func activate(_ processID: pid_t) async { await base.activate(processID) }
        func secondsSincePersonInput() -> TimeInterval { 600 }
    }

    let root = FileManager.default.temporaryDirectory.appending(path: "native-diagnostic-\(UUID())")
    let workspace: WorkspaceStub
    let reader: TreeStub
    private let nativeWorkspace: any MacWorkspace
    var lateLaunchAttempts: Int { (nativeWorkspace as? RefusingLaunch)?.attempts.withLock { $0 } ?? 0 }
    var nativeEnabled = true
    var quitAccepted = true
    var cancelAfterLaunch = false
    let bName: String
    var available: [String]
    var bWasRunning = true
    var seatLaunches: [String] = []
    var adopted: [pid_t] = []
    var quitRequests: [pid_t] = []
    var lines: [String] = []
    private var toolsWereUsed = false
    private var sequence = 0
    private var sceneTitle = "Public window"

    lazy var ledger = LaunchLedger(terminate: { [weak self] pid in self?.quitRequests.append(pid) },
                                  isTerminated: { _ in false })
    lazy var broker = SeatBroker(configuration: .init(perceptionStoreDirectory: root.appending(path: "Perception"),
        recordingDirectory: root.appending(path: "Runs")), ledger: ledger)
    lazy var desktop = BrokeredAutomationSession(broker: broker, workerID: UUID(), knowledgeDirectory: root,
        allowsDestructive: false, claims: AppClaims(), resolving: { $0 }, missingGrant: { nil }, requestGrants: {},
        seating: { [unowned self] session, bundle, title in
            session.stopHost = { nil }
            session.openingPlatform = AgentSession.OpeningPlatform(
                resolve: { [unowned self] _ in
                    TargetApp(pid: bWasRunning ? 602 : nil, bundleID: bundle, name: bName, bundleURL: nil, windows: [])
                },
                launch: { [unowned self] _ in
                    seatLaunches.append(bundle)
                    if !bWasRunning { ledger.record(.openedByAgent, for: 602) }
                    if cancelAfterLaunch { withUnsafeCurrentTask { $0?.cancel() } }
                    let windows = available.enumerated().map { index, title in
                        TargetWindow(pid: 602, windowNumber: 702 + index, title: title,
                            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
                    }
                    return TargetApp(pid: 602, bundleID: bundle, name: bName, bundleURL: nil, windows: windows)
                },
                adopt: { [unowned self] window in adopted.append(window.pid); sceneTitle = window.title },
                release: {}, handback: { nil }, hasUnrestoredWindow: { false },
                quitUnseated: { [unowned self] pid in
                    ledger.quitUnseated(pid, terminate: { pid in quitRequests.append(pid); return quitAccepted })
                })
            let opened = session.isUsingApp
                ? try await session.openReplacingApplication(bundle, window: title)
                : try await session.open(applicationNamed: bundle, windowTitled: title)
            return (opened, SeatTarget())
        }, perceiving: { [unowned self] _, _ in
            SceneSnapshot(bundleID: "test.b", appName: bName, windowTitle: sceneTitle,
                viewportPixelSize: .init(width: 800, height: 600), elements: [])
        }, runningApplication: { _ in Running() }, stoppedForGood: { _ in false })
    lazy var native = MacAutomationSession(knowledgeDirectory: root, roles: MacRoles(reader: reader, actor: reader,
        delivery: NoDelivery(), person: nil, notifications: QuietNotifications(), controls: NoControls(),
        serverWindows: { pid in [(number: Int(pid) + 700, frame: MacSessionTests.frame)] },
        identity: { [bName] pid in pid == 501 ? ("test.b", bName) : ("test.a", "Public A app") }),
        workspace: nativeWorkspace, leases: MacAppLeases())
    lazy var routing = RoutingAutomationSession(native: nativeEnabled ? native : nil, desktop: desktop)
    lazy var tools: AutomationTools = {
        let tools = AutomationTools(session: routing)
        tools.producer = CallProducer(source: .app, streamID: "native-diagnostic", traceID: "native-diagnostic")
        tools.record = { [unowned self] in lines.append($0) }
        return tools
    }()
    lazy var router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)

    init(bName: String = "Public app", available: [String] = ["Public A.txt", "Public B.txt"],
         candidates: Int = 1, lateFailure: MacLaunchFailure? = nil) {
        self.bName = bName
        self.available = available
        let a = MacApp(bundleID: "test.a", url: URL(filePath: "/Applications/PublicA.app"), names: ["Public A app"])
        let b = MacApp(bundleID: "test.b", url: URL(filePath: "/Applications/PublicB.app"), names: [bName])
        let otherCandidates = (1..<candidates).map { index in
            MacApp(bundleID: "test.b\(index)", url: URL(filePath: "/Applications/PublicB\(index).app"), names: [bName])
        }
        workspace = WorkspaceStub(apps: [a, b] + otherCandidates, processIDs: [a.bundleID: 500, b.bundleID: 501])
        if let lateFailure { nativeWorkspace = RefusingLaunch(base: workspace, failure: lateFailure) }
        else { nativeWorkspace = workspace }
        var aTree = MacSessionTests.rich
        aTree.title = "Public A window"
        var bTree = MacSessionTests.rich
        bTree.title = "Public B.txt"
        reader = TreeStub(aTree, trees: [501: bTree])
    }

    func call(_ name: String, _ fields: [String: JSONValue]) async throws -> JSONValue {
        toolsWereUsed = true
        sequence += 1
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(sequence)),
            "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(fields)])])
        let reply = try #require(await router.handle(request))
        #expect(reply["error"] == .null)
        return reply["result"]
    }

    func text(_ value: JSONValue) -> String {
        value["content"].array?.compactMap { $0["text"].string }.joined(separator: "\n") ?? ""
    }

    func assertNoPrivateArchiveValues(_ secrets: [String]) throws {
        if let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in paths where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let bytes = try Data(contentsOf: file)
                for secret in secrets { #expect(bytes.range(of: Data(secret.utf8)) == nil, "Leak in \(file.lastPathComponent)") }
            }
        }
    }

    func close() async throws {
        await routing.close()
        if toolsWereUsed {
            tools.record = nil
            let memory = MemoryService.shared(for: root)
            await memory.close()
            MemoryService.forget(root)
        }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
