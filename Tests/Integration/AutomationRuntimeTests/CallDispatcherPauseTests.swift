import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

@Suite("CallDispatcher pause lifetime")
@MainActor
struct CallDispatcherPauseTests {
    @Test func standaloneObservationBetweenEndAndAnswerKeepsThePause() async throws {
        let service = try W.service()
        MemoryService.install(service)
        let session = PauseSession(memory: service, exit: .answer, endsBeforeObservation: true)
        let tools = AutomationTools(session: session)
        var inspected = false
        tools.record = { line in
            if line.hasPrefix("← observe {") {
                let rows = try rawRows("SELECT event_id FROM brain_applications", at: service.url)
                #expect(rows.isEmpty)
                inspected = true
            }
        }
        _ = try await tools.call("observe", .object([:]))
        #expect(inspected)
        #expect(await service.flush(within: .seconds(5)))
        #expect(await service.status().written == 1)
        await service.close()
    }

    @Test(arguments: [false, true])
    func callMinimizationIsolated(batch: Bool) async throws {
        async let first: Void = checkCallSecret("731", batch: batch)
        async let second: Void = checkCallSecret("942", batch: batch)
        _ = try await (first, second)
        #expect(CallMinimization.current == nil)
    }

    private func checkCallSecret(_ secret: String, batch: Bool) async throws {
        let service = try W.service()
        MemoryService.install(service)
        let session = PauseSession(memory: service, exit: .answer)
        let tools = AutomationTools(session: session)
        let plan = try await tools.call("plan", .object(["request": .string("Choose the private value"),
            "rows": .array([.object(["title": .string("Choose the private value")])])]))
        #expect(plan["isError"] != .bool(true))
        if batch {
            _ = try await tools.call("batch", .object([
                "steps": .array(["731", "942"].map { value in
                    .object(["operation": .string("select"), "control": .string("Password"), "item": .string(value), "step": .string("r1")])
                })
            ]))
            #expect(session.snapshots == [["731"], ["942"]])
        } else {
            _ = try await tools.call("call", .object(["name": .string("select"), "arguments": .object([
                "control": .string("Password"), "item": .string(secret), "step": .string("r1")
            ])]))
            #expect(session.snapshots == [[secret]])
        }
        try await PauseTestWait.untilWritten(service)
        #expect(await service.status().written == 1)
        await service.close()
    }

    enum Exit: Sendable, CaseIterable { case answer, answerError, finishError, cancellation }

    @Test(arguments: Exit.allCases)
    func derivedStartsAfterTheAnswer(exit: Exit) async throws {
        let service = try W.service()
        MemoryService.install(service)
        let session = PauseSession(memory: service, exit: exit)
        let tools = AutomationTools(session: session)
        var inspected = false
        tools.record = { line in
            if line.hasPrefix("← observe {") {
                #expect(try rawRows("SELECT event_id FROM brain_applications", at: service.url).isEmpty)
                inspected = true
                if exit == .finishError { throw PauseSession.Failure() }
            }
        }
        let task = Task { @MainActor in
            do {
                _ = try await tools.call("observe", .object([:]))
                #expect(exit == .answer)
            } catch {
                #expect(exit != .answer)
            }
        }
        await task.value
        let recorder = try #require(session.recorder)
        try await PauseTestWait.untilWritten(service)
        #expect(await service.flush(within: .seconds(5)))
        #expect(try await service.application(.observe(CaptureSampleKey(eventID: recorder.eventID, phase: .current))) == nil)
        #expect(await service.status().written == 1)
        if exit == .answer || exit == .finishError { #expect(inspected) }
        await service.close()
    }
}

@MainActor
private final class PauseSession: AutomationSessionOperating {
    struct Failure: Error {}
    let memory: MemoryService
    let exit: CallDispatcherPauseTests.Exit
    let endsBeforeObservation: Bool
    let id: UUID? = UUID()
    var recorder: CallRecorder?
    var snapshots: [[String]] = []
    var memoryDirectory: URL? { memory.directory }
    var memoryApplication: String? { W.bundle }

    init(memory: MemoryService, exit: CallDispatcherPauseTests.Exit, endsBeforeObservation: Bool = false) {
        self.memory = memory
        self.exit = exit
        self.endsBeforeObservation = endsBeforeObservation
    }

    func observe() async throws -> SceneSnapshot {
        recorder = CallRecorder.current
        if endsBeforeObservation {
            try await recorder?.end(.completed, result: nil, tool: .observe)
        }
        let scene = await recorder?.observe(Self.window) ?? Self.window.scene
        #expect(await memory.status().written == 0)
        if exit == .answerError { throw Failure() }
        if exit == .cancellation {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        return scene
    }

    static var window: PerceivedWindow {
        W.window([W.open, SceneElement(id: "password", kind: .control, label: "Password",
            bounds: .init(x: 0.3, y: 0.3, width: 0.2, height: 0.1), role: "AXPopUpButton")])
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw Failure() }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw Failure()
    }
    func select(control: String, item: String) async throws -> ActOutcome {
        let snapshot = try #require(CallMinimization.current)
        let recorder = try #require(CallRecorder.current)
        let admitted = await recorder.admittedMinimization()
        #expect(snapshot.secrets == admitted.secrets)
        #expect(snapshot.minimize(text: item).0 == ValueMinimization.marker)
        await Task.yield()
        #expect(CallMinimization.current?.secrets == snapshot.secrets)
        snapshots.append(snapshot.secrets)
        return ActOutcome(.foundActed, "selected", scene: Self.window.scene)
    }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw Failure() }
    func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        throw Failure()
    }
    func close() async {}
}
