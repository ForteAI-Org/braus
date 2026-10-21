import AppAdapters
import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// P2-06 through the tools: a change whose effect is not known blocks its repeat and the calls that act on what it
/// reached, for the producer's stream and across a restart of the tools, until a later completed call read it and the
/// agent reconciled it; the reconciliation is a new fact, the call's end untouched. A started call whose process ended
/// gets `executor_terminated` from the next process's sweep, never an invented end. A person's refusal kept in a refusal
/// file outlives the barrier that noted it.
@MainActor
@Suite("P2-06: uncertain effects reconciled, never replayed; refusals kept", .serialized)
struct ReconciliationTests {

    /// Reminders whose completion answers sent and not read back, and whose read finds the reminder.
    final class RemindersFake: AppAdapting, @unchecked Sendable {
        let name = "reminders"
        let appNames = ["Reminders"]
        let bundleIDs: Set<String> = ["com.apple.reminders"]
        let verbs = [
            AdapterVerb("complete_reminder", "Complete.", parameters: [AdapterParameter("id", .string, "id")],
                        safety: .write, readBack: "the reminder", results: .identifiersAndDates),
            AdapterVerb("find_reminders", "Find.", parameters: [AdapterParameter("query", .string, "q", required: false)],
                        safety: .read, readBack: "the store", results: .identifiersAndDates),
        ]
        private(set) var completed = 0
        var readID = "r-1"
        var readCompleted = true
        func availability() async -> AdapterAvailability { .ready }
        func requestPermission() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            if verb == "complete_reminder" {
                completed += 1
                return AdapterOutcome(.actedUnverified, "The store took the completion; it did not read back.",
                                      result: .object(["id": arguments["id"]]))
            }
            return .confirmed("1 reminder.", .object(["reminders": .array([.object(["id": .string(readID), "completed": .bool(readCompleted)])])]))
        }
    }

    static func tools(_ knowledge: URL, _ adapter: RemindersFake) -> AutomationTools {
        let tools = AutomationTools(session: CallDispatchRecordTests.RouteFake(.desktop, memory: knowledge))
        tools.adapters = AppAdapters([adapter])
        tools.producer = CallProducer(source: .app, streamID: "p206", traceID: "reconcile-\(UUID().uuidString)")
        return tools
    }

    static func complete(_ tools: AutomationTools, _ id: String) async throws -> JSONValue {
        try await tools.call("app_call", .object(["app": .string("Reminders"), "verb": .string("complete_reminder"),
                                                  "arguments": .object(["id": .string(id)])]))
    }

    @Test("an unverified change blocks its repeat and a call on what it reached, across a restart; a read and reconcile lift it; the end is untouched")
    func uncertainEffectBlocksUntilReconciled() async throws {
        let knowledge = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let adapter = RemindersFake()
        let first = Self.tools(knowledge, adapter)
        _ = try await Self.complete(first, "r-1")
        await #expect(throws: AutomationFailure.self) { _ = try await Self.complete(first, "r-1") }
        #expect(adapter.completed == 1, "nothing was sent again")
        // Another call of the stream naming the reminder it reached is a dependent: blocked too.
        await #expect(throws: AutomationFailure.self) {
            _ = try await first.call("app_call", .object(["app": .string("Reminders"), "verb": .string("complete_reminder"),
                                                          "arguments": .object(["id": .string("r-1")])]))
        }
        // A restart: new tools on the same archive and stream still refuse.
        let second = Self.tools(knowledge, adapter)
        await #expect(throws: AutomationFailure.self) { _ = try await Self.complete(second, "r-1") }
        #expect(adapter.completed == 1)
        // Another reminder is no repeat and no dependent.
        _ = try await Self.complete(second, "r-2")
        #expect(adapter.completed == 2)

        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        let unresolved = try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil)
        let uncertain = try #require(unresolved.first { $0.isRepeated(by: .appCall(app: "Reminders", verb: "complete_reminder",
                                                                                   arguments: #"{"id":"r-1"}"#)) })
        // A later read, then the agent's reconciliation, with that read as evidence.
        let read = try await second.call("app_call", .object(["app": .string("Reminders"), "verb": .string("find_reminders")]))
        #expect((read["content"].array?.first?["text"].string ?? "").contains("r-1"))
        _ = await memory.flush(within: .seconds(5))
        let reads = try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil)
        #expect(reads.count == 2, "the read is no uncertain call: \(reads.map(\.eventID))")
        let evidence = try #require(try await Self.lastCall(memory, verb: "find_reminders"))
        let answer = try await second.call("memory_task", .object([
            "operation": .string("reconcile"), "call": .string(uncertain.eventID), "finding": .string("happened"),
            "evidence": .string(evidence),
        ]))
        #expect((answer["content"].array?.first?["text"].string ?? "").contains("reconciled"), "\(answer)")
        // Resolved: the call is no longer blocking; its own end is as it was.
        let after = try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil)
        #expect(!after.contains { $0.eventID == uncertain.eventID })
        let facts = try await memory.perform { try await $0.facts.reconciliations(of: uncertain.eventID) }
        #expect(facts.map(\.kind) == [.observed] && facts.first?.finding == .happened && facts.first?.declaredBy == .agent)
        let effect = try await memory.perform { try await $0.facts.effect(of: uncertain.eventID) }
        #expect(effect?.performed == .uncertain, "the original fact is kept")
        _ = try await Self.complete(second, "r-1")
        #expect(adapter.completed == 3, "a repeat after the evidence is the agent's decision, not a replay")
        await MemoryService.closeAll()
    }

    static func lastCall(_ memory: MemoryService, verb: String) async throws -> String? {
        let archive = try SQLiteConnection(path: memory.url.path, readOnly: true)
        defer { archive.close() }
        return try archive.query(
            "SELECT a.event_id FROM memory_agent_actions a JOIN memory_call_adapter_dispatches d ON d.event_id = a.event_id WHERE d.verb = ? ORDER BY a.started_at_ms DESC LIMIT 1",
            [.text(verb)]) { try $0.text(0) }.first ?? nil
    }

    @Test("a started call whose process ended gets executor_terminated from the next sweep; one still running is left")
    func sweepOfEndedExecutors() async throws {
        let knowledge = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let memory = MemoryService.shared(for: knowledge)
        let current = try #require(MemoryExecutor.current(for: knowledge, source: .app))
        // Two earlier processes: one ended (its lock file free), one whose lock this test holds.
        let folder = MemoryExecutor.lockFolder(of: knowledge)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: "ended-1.lock").path, contents: Data())
        guard case .success(let held) = AppClaims.lock("alive-1", in: folder) else { Issue.record("no lock"); return }
        defer { close(held) }
        let recorder = { (executor: String, id: String) async throws in
            let context = ActionContext(source: .app, streamID: "sweep", traceID: "sweep")
            let call = try AgentCallRecord(event: context.event(app: nil, occurredAtMS: 1, monotonicNS: 1),
                                           request: .appCall(app: "Reminders", verb: "complete_reminder", arguments: "{\"id\":\"\(id)\"}"))
            var opening = try OperationOpening(call: call, startedAtMS: 1)
            opening.executor = ExecutorRecord(executorID: executor, source: "app", processID: 1, startedAtMS: 1)
            let opened = opening
            _ = try await memory.perform { try await $0.facts.open(opened) }
            return call.event.eventID
        }
        let ended = try await recorder("ended-1", "a"), alive = try await recorder("alive-1", "b")
        // The sweep of this process runs once per folder; a fresh flag for this folder makes it run here.
        let reconciled = await MemoryExecutor.sweep(memory, folder: knowledge, current: current)
        #expect(reconciled == [ended], "\(reconciled)")
        let facts = try await memory.perform { try await $0.facts.reconciliations(of: ended) }
        #expect(facts.map(\.kind) == [.executorTerminated] && facts.first?.declaredBy == .braus)
        #expect(try await memory.perform { try await $0.facts.reconciliations(of: alive) }.isEmpty)
        let statuses = try await memory.calls(inTrace: "sweep").map(\.progress.status)
        #expect(statuses.allSatisfy { $0 == .started }, "no end is invented: \(statuses)")
        await MemoryService.closeAll()
    }
    @Test("unrelated status must not reconcile an uncertain mutation")
    func unrelatedStatusIsNotEvidence() async throws {
        let folder = StructuredCallFactsTests.knowledge()
        defer {try? FileManager.default.removeItem(at: folder)}
        let tools = ReconciliationTests.tools(folder, ReconciliationTests.RemindersFake())
        tools.producer = CallProducer(source: .app, streamID: "audit-status", traceID: "audit-status")
        _ = try await ReconciliationTests.complete(tools, "r-1")
        let memory=MemoryService.shared(for: folder)
        let uncertain=try #require(try await memory.unresolvedCalls(source: .app, streamID: "audit-status", excludingExecutor: nil).first)
        _ = try await tools.call("status", .object([:]))
        let calls=try await memory.calls(inTrace: "audit-status")
        let status=try #require(calls.first {$0.request.tool == .status})
        let answer=try await tools.call("memory_task", .object([
          "operation": .string("reconcile"), "call": .string(uncertain.eventID),
          "finding": .string("not_happened"), "evidence": .string(status.event.eventID)]))
        #expect(answer["isError"].bool == true, "a status of TCC/session cannot prove a reminder was not completed")
        let left=try await memory.unresolvedCalls(source: .app, streamID: "audit-status", excludingExecutor: nil)
        #expect(left.contains {$0.eventID == uncertain.eventID}, "uncertain mutation was cleared by an unrelated status")
        // Simulate an invalid observation already written by the previous build; it must stay historical without resolving.
        let legacy = try SQLiteConnection(path: memory.url.path)
        let insertion = try legacy.prepare("""
            INSERT INTO memory_call_reconciliations
            (event_id, sequence, kind, finding, evidence_event_id, declared_by, recorded_at_ms)
            VALUES (?, 1, 'observed', 'not_happened', ?, 'agent', 1)
            """)
        try insertion.bind([.text(uncertain.eventID), .text(status.event.eventID)])
        _ = try insertion.step()
        insertion.finalize()
        legacy.close()
        let historical = try await memory.unresolvedCalls(source: .app, streamID: "audit-status", excludingExecutor: nil)
        #expect(historical.contains { $0.eventID == uncertain.eventID })
        #expect(try await memory.perform { try await $0.facts.reconciliations(of: uncertain.eventID) }.count == 1)
        await MemoryService.closeAll()
    }
    @Test("resource, finding and producer scope must agree before an uncertain effect is resolved")
    func specificEvidence() async throws {
        let folder = StructuredCallFactsTests.knowledge()
        defer { try? FileManager.default.removeItem(at: folder) }
        let adapter = RemindersFake()
        let tools = Self.tools(folder, adapter)
        _ = try await Self.complete(tools, "r-1")
        let memory = MemoryService.shared(for: folder)
        let call = try #require(try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil).first)
        func readAndReconcile(_ finding: String) async throws -> JSONValue {
            _ = try await tools.call("app_call", .object(["app": .string("Reminders"), "verb": .string("find_reminders")]))
            let evidence = try #require(try await Self.lastCall(memory, verb: "find_reminders"))
            return try await tools.call("memory_task", .object([
                "operation": .string("reconcile"), "call": .string(call.eventID),
                "finding": .string(finding), "evidence": .string(evidence)]))
        }
        adapter.readID = "another-reminder"
        #expect(try await readAndReconcile("happened")["isError"].bool == true)
        adapter.readID = "r-1"
        adapter.readCompleted = false
        #expect(try await readAndReconcile("happened")["isError"].bool == true)
        let originalProducer = tools.producer
        tools.producer = CallProducer(source: .app, streamID: "foreign", traceID: "foreign")
        #expect(try await readAndReconcile("not_happened")["isError"].bool == true)
        tools.producer = originalProducer
        #expect(try await readAndReconcile("not_happened")["isError"].bool != true)
        #expect(try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil).isEmpty)
        #expect(try await memory.perform { try await $0.facts.effect(of: call.eventID) }?.performed == .uncertain)
        await MemoryService.closeAll()
    }

}
