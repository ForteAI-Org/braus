import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// Adapter failures distinguish a Seat cancellation before invocation from an error after invocation.
@MainActor
@Suite(.serialized)
struct AdapterDispatchBoundaryTests {
    actor RequiredPathAdapter: AppAdapting {
        nonisolated let name = "strict-boundary"
        nonisolated let appNames = ["Synthetic"]
        nonisolated let bundleIDs: Set<String> = ["example.synthetic"]
        nonisolated let verbs = [AdapterVerb("change", "Change synthetic state.",
            parameters: [AdapterParameter("path", .string, "A nonempty synthetic path.")],
            safety: .write, readBack: "synthetic state")]
        var invocations = 0
        func availability() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            invocations += 1
            return .confirmed("Updated.")
        }
    }

    @Test func rejectedSemanticArgumentLeavesNoUnresolvedEffectAndAllowsTheNextCall() async throws {
        let directory = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = RequiredPathAdapter()
        let tools = AutomationTools(session: Session(directory: directory, hasSeat: false),
            adapters: AppAdapters([adapter]))
        tools.producer = CallProducer(source: .app, streamID: "semantic-boundary", traceID: "semantic-boundary")
        try await StructuredCallFactsTests.plan(tools, request: "Exercise semantic argument validation")
        await #expect(throws: AdapterFailure.self) {
            _ = try await tools.call("call", .object(["name": .string("strict-boundary.change"),
                "arguments": .object(["path": .string(""), "step": .string("r1")])]))
        }
        #expect(await adapter.invocations == 0)
        let records = try await CallDispatchRecordTests.recorded("semantic-boundary", in: directory)
        let rejected = try #require(records.last { $0.tool == "app_call" })
        #expect(rejected.performed == OperationCheck.Performed.none)
        let memory = MemoryService.shared(for: directory)
        #expect(try await memory.unresolvedCalls(source: .app, streamID: "semantic-boundary", excludingExecutor: nil).isEmpty)
        _ = try await tools.call("call", .object(["name": .string("strict-boundary.change"),
            "arguments": .object(["path": .string("synthetic"), "step": .string("r1")])]))
        #expect(await adapter.invocations == 1)
        await memory.close()
    }

    actor Adapter: AppAdapting {
        nonisolated let name = "boundary"
        nonisolated let appNames = ["Synthetic"]
        nonisolated let bundleIDs: Set<String> = ["example.synthetic"]
        nonisolated let scriptedApplication: String? = "example.synthetic"
        nonisolated let verbs = [AdapterVerb("change", "Change synthetic state.", safety: .write, readBack: "synthetic state")]
        var invocations = 0
        func availability() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            invocations += 1
            throw AdapterFailure("Synthetic failure after invocation")
        }
    }

    final class Session: AutomationSessionOperating {
        let memoryDirectory: URL?
        let hasSeat: Bool
        var id: UUID? { nil }
        init(directory: URL, hasSeat: Bool) { memoryDirectory = directory; self.hasSeat = hasSeat }
        func openOnSeat(application: String) async throws -> SceneSnapshot { throw CancellationError() }
        func open(application: String, window: String?) async throws -> SceneSnapshot { throw CancellationError() }
        func observe() async throws -> SceneSnapshot { throw CancellationError() }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
            throw CancellationError()
        }
        func select(control: String, item: String) async throws -> ActOutcome { throw CancellationError() }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw CancellationError() }
        func close() async {}
    }

    @Test(arguments: [true, false])
    func invocationBoundaryDeterminesTheRecordedEffect(cancelBeforeInvocation: Bool) async throws {
        let directory = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = Adapter()
        let tools = AutomationTools(session: Session(directory: directory, hasSeat: cancelBeforeInvocation), adapters: AppAdapters([adapter]))
        tools.producer = CallProducer(source: .app, streamID: "boundary", traceID: "boundary")
        try await StructuredCallFactsTests.plan(tools, request: "Exercise a synthetic adapter")
        do {
            _ = try await tools.call("call", .object(["name": .string("boundary.change"),
                "arguments": .object(["step": .string("r1")])]))
        } catch is CancellationError {
            #expect(cancelBeforeInvocation)
        } catch is AdapterFailure {
            #expect(!cancelBeforeInvocation)
        }
        let records = try await CallDispatchRecordTests.recorded("boundary", in: directory)
        let call = try #require(records.last { $0.tool == "app_call" })
        #expect(await adapter.invocations == (cancelBeforeInvocation ? 0 : 1))
        #expect(call.performed == (cancelBeforeInvocation ? OperationCheck.Performed.none : .uncertain))
        #expect((call.dispatch == nil) == cancelBeforeInvocation)
        let memory = MemoryService.shared(for: directory)
        let unresolved = try await memory.unresolvedCalls(source: .app, streamID: "boundary", excludingExecutor: nil)
        #expect(unresolved.isEmpty == cancelBeforeInvocation)
        if cancelBeforeInvocation {
            let effect = try await memory.perform { try await $0.facts.effect(of: call.eventID) }
            #expect(effect?.notSentReason != nil)
        }
        await memory.close()
    }
}
