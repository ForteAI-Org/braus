import AppKit
import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SeatDriving
import SeatSession
@testable import SeatBroker
import Testing

/// HO03: preregistered observation-side-effect variant; lower OS operations alone are simulated.
@MainActor
struct NR01ObservationIndependentHoldoutTests {
    @Test
    func failedHeldSelectionDoesNotClaimTheObservedWindowStayedUnchanged() async throws {
        let f = ObservationHoldoutFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let opened = try await f.call("open_session", ["app": .string(f.publicApp)])
            #expect(opened["isError"].bool != true)
            let original = try #require(f.session.id)
            let lease = f.broker.queue.entries
            let secrets = [f.privateRequested, f.privateAvailable]
            let plan = try await f.call("plan", ["request": .string("Inspect a held window"),
                "rows": .array([.object(["title": .string("Inspect the requested window")])]),
                "inputs": .array(secrets.enumerated().map { index, value in
                    .object(["name": .string("private\(index)"), "value": .string(value), "secret": .bool(true)])
                })])
            #expect(plan["isError"].bool != true)
            let refused = try await f.call("open_session", ["app": .string(f.publicApp), "window": .string(f.privateRequested)])
            let message = f.text(refused)
            #expect(refused["isError"].bool == true)
            #expect(message.contains("uncertain") && !message.contains("not_sent"))
            #expect(!message.contains("The held window was not changed"))
            #expect(!message.contains("window is unchanged"))
            #expect(!message.contains("was asked to quit"))
            if let cause = f.failure {
                #expect(cause.state == .previousRetained && cause.causeCode == "opening_window_title_mismatch")
                if case .windowTitleMismatch(let selection)? = cause.reason {
                    #expect(selection.matches == 0 && !selection.openingAttempted)
                } else { Issue.record("The production exact guard lost its structural selection facts") }
                #expect(message.contains(ModelText.openingFailure(cause, minimization: .init(secrets: secrets))))
            } else { Issue.record("The production exact guard's typed cause did not reach the session boundary") }
            #expect(f.session.id == original && f.session.memoryApplication == "org.nr01.held")
            #expect(f.broker.queue.entries == lease && f.openings == 1 && f.explicitSwitches == 0)
            #expect(f.simulatedObservationEffects == 1 && f.sceneTitle == f.publicObservedB)
            for value in secrets {
                #expect(!message.contains(value))
                #expect(!f.transcript.joined(separator: "\n").contains(value))
            }
            // Same app/session identity is compatible with a different window observed after the failed guard.
            let observed = try await f.call("observe", ["full": .bool(true)])
            #expect(observed["isError"].bool != true && f.text(observed).contains(f.publicObservedB))
            #expect(f.session.id == original && f.openings == 1 && f.explicitSwitches == 0)
            // Neighbor control: an explicitly corrected, unique title remains usable.
            let corrected = try await f.call("open_session", ["app": .string(f.publicApp), "window": .string(f.publicObservedB)])
            #expect(corrected["isError"].bool != true && f.text(corrected).contains(f.publicObservedB))
            #expect(f.session.id == original && f.broker.queue.entries == lease)
            #expect(f.openings == 1 && f.explicitSwitches == 1)
            await f.stop()
            try assertObservationArchiveIsPrivate(root: f.root, secrets: secrets)
        } catch {
            await f.stop()
            throw error
        }
    }
}

@MainActor
private final class ObservationHoldoutFixture {
    private final class Running: NSRunningApplication {
        override var isTerminated: Bool { false }
        override var bundleIdentifier: String? { "org.nr01.held" }
        override var localizedName: String? { "Public held app" }
        override var processIdentifier: pid_t { 601 }
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "nr01-observation-\(UUID())")
    let publicApp = "Public held app"
    let publicObservedB = "Observer followed window B"
    let privateRequested = "NR01_HO03_PRIVATE_REQUESTED"
    let privateAvailable = "NR01_HO03_PRIVATE_AVAILABLE"
    var sceneTitle = "Original held window A"
    var openings = 0
    var explicitSwitches = 0
    var simulatedObservationEffects = 0
    var sequence = 0
    var stopped = false
    var failure: ApplicationOpeningFailure?
    var transcript: [String] = []
    lazy var broker = SeatBroker(configuration: .init(perceptionStoreDirectory: root.appending(path: "Perception"),
        recordingDirectory: root.appending(path: "Runs")))
    lazy var session = BrokeredAutomationSession(broker: broker, workerID: UUID(), knowledgeDirectory: root,
        allowsDestructive: false, claims: AppClaims(), resolving: { _ in "org.nr01.held" }, missingGrant: { nil },
        requestGrants: {}, seating: { [unowned self] _, _, _ in
            openings += 1
            return (TargetApp(pid: 601, bundleID: "org.nr01.held", name: publicApp, bundleURL: nil, windows: []), SeatTarget())
        }, perceiving: { [unowned self] _, _ in
            SceneSnapshot(bundleID: "org.nr01.held", appName: publicApp, windowTitle: sceneTitle,
                viewportPixelSize: .init(width: 100, height: 100), elements: [])
        }, runningApplication: { _ in Running() }, switching: { [unowned self] _, _, title, application in
            // Models the lower observation following B before the real guard; it is not an explicit target switch.
            simulatedObservationEffects += 1
            sceneTitle = publicObservedB
            let windows = [publicObservedB, privateAvailable].enumerated().map { index, value in
                TargetWindow(pid: 601, windowNumber: 701 + index, title: value, frame: .zero)
            }
            do {
                _ = try BrokeredAutomationSession.exactHeldWindow(in: windows, title: title, application: application)
                explicitSwitches += 1
            } catch let error as ApplicationOpeningFailure { failure = error; throw error }
        }, stoppedForGood: { _ in false })
    lazy var tools: AutomationTools = {
        let tools = AutomationTools(session: session)
        tools.record = { [unowned self] in transcript.append($0) }
        return tools
    }()
    lazy var router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)

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
    func stop() async {
        guard !stopped else { return }
        stopped = true
        tools.record = nil
        await session.close()
        let memory = MemoryService.shared(for: root)
        await memory.close()
        MemoryService.forget(root)
    }
}

/// Kept synchronous because DirectoryEnumerator's iterator is unavailable in async contexts.
private func assertObservationArchiveIsPrivate(root: URL, secrets: [String]) throws {
    if let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
        for case let file as URL in paths where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let bytes = try Data(contentsOf: file)
            for value in secrets { #expect(bytes.range(of: Data(value.utf8)) == nil, "Private observation data in \(file.lastPathComponent)") }
        }
    }
}
