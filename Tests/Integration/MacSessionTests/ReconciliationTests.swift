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

    static func tools(_ knowledge: URL, _ adapter: RemindersFake, profile: SessionProfile = .app) -> AutomationTools {
        let tools = AutomationTools(session: CallDispatchRecordTests.RouteFake(.desktop, memory: knowledge),
            adapters: AppAdapters([adapter]), profile: profile)
        tools.producer = CallProducer(source: .app, streamID: "p206", traceID: "reconcile-\(UUID().uuidString)")
        return tools
    }

    static func complete(_ tools: AutomationTools, _ id: String) async throws -> JSONValue {
        if tools.openTask == nil { try await StructuredCallFactsTests.plan(tools, request: "Complete synthetic reminders") }
        return try await tools.call("call", .object(["name": .string("reminders.complete_reminder"),
                                                  "arguments": .object(["step": .string("r1"), "id": .string(id)])]))
    }

    @Test("an unverified change blocks its repeat across a restart; public read evidence and reconciliation lift it without teaching", arguments: [SessionProfile.Memory.readLearn, .read, .off])
    func uncertainEffectBlocksUntilReconciled(_ mode: SessionProfile.Memory) async throws {
        let knowledge = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let adapter = RemindersFake()
        let first = Self.tools(knowledge, adapter, profile: SessionProfile.app.replacing(memory: mode))
        _ = try await Self.complete(first, "r-1")
        await #expect(throws: AutomationFailure.self) { _ = try await Self.complete(first, "r-1") }
        #expect(adapter.completed == 1, "nothing was sent again")
        // Another call of the stream naming the reminder it reached is a dependent: blocked too.
        await #expect(throws: AutomationFailure.self) {
            _ = try await first.call("call", .object(["name": .string("reminders.complete_reminder"),
                                                          "arguments": .object(["step": .string("r1"), "id": .string("r-1")])]))
        }
        _ = try await first.call("end", .object(["outcome": .string("abandoned")]))
        // A restart: new tools on the same archive and stream still refuse.
        let second = Self.tools(knowledge, adapter, profile: SessionProfile.app.replacing(memory: mode))
        await #expect(throws: AutomationFailure.self) { _ = try await Self.complete(second, "r-1") }
        #expect(adapter.completed == 1)
        // Another reminder is no repeat and no dependent.
        _ = try await Self.complete(second, "r-2")
        #expect(adapter.completed == 2)

        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        let unresolved = try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil)
        let uncertain = try #require(unresolved.first { $0.isRepeated(by: .appCall(app: "reminders", verb: "complete_reminder",
                                                                                   arguments: #"{"id":"r-1"}"#)) })
        // A later read, then the agent's reconciliation, with that read as evidence.
        let read = try await second.call("call", .object(["name": .string("reminders.find_reminders"), "arguments": .object([:])]))
        #expect((read["content"].array?.first?["text"].string ?? "").contains("r-1"))
        _ = await memory.flush(within: .seconds(5))
        let reads = try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil)
        #expect(reads.count == 2, "the read is no uncertain call: \(reads.map(\.eventID))")
        let secondTrace = try #require(second.producer.traceID)
        let evidence = try #require(read["structuredContent"]["recorded_call"].string,
                                    "A recorded read exposes its evidence identity to the model")
        #expect((read["content"].array?.first?["text"].string ?? "").contains("recorded_call: " + evidence))
        #expect(try await Self.lastCall(memory, verb: "find_reminders", trace: secondTrace) == evidence)
        let found = try await second.call("find", .object(["query": .string("reconcile_call uncertain write recorded read evidence")]))
        #expect(Self.payload(found)["capabilities"].array?.contains { $0["name"].string == "reconcile_call" } == true)
        #expect(!second.toolDefinitions.contains { $0["name"].string == "reconcile_call" })
        let callsBefore = try await memory.calls(inTrace: secondTrace).count
        let reconciled = try await second.call("call", .object(["name": .string("reconcile_call"), "arguments": .object([
            "call": .string(uncertain.eventID), "finding": .string("happened"), "evidence": .string(evidence)
        ])]))
        #expect(Self.payload(reconciled)["status"].string == "reconciled")
        #expect(try await memory.calls(inTrace: secondTrace).count == callsBefore, "Ledger recovery creates no app call or recursive recorder")
        // Resolved: the call is no longer blocking; its own end is as it was.
        let after = try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil)
        #expect(!after.contains { $0.eventID == uncertain.eventID })
        let facts = try await memory.perform { try await $0.facts.reconciliations(of: uncertain.eventID) }
        #expect(facts.map(\.kind) == [.observed] && facts.first?.finding == .happened && facts.first?.declaredBy == .agent)
        let effect = try await memory.perform { try await $0.facts.effect(of: uncertain.eventID) }
        #expect(effect?.performed == .uncertain, "the original fact is kept")
        _ = try await Self.complete(second, "r-1")
        #expect(adapter.completed == 3, "a repeat after the evidence is the agent's decision, not a replay")
        _ = try await second.call("end", .object(["outcome": .string("completed")]))
        let inspection = try SQLiteConnection(path: memory.url.path)
        let versions = try inspection.query("SELECT count(*) FROM memory_procedure_versions") { $0.integer(0) ?? -1 }
        inspection.close()
        #expect(versions == [0], "Operational reconciliation does not teach a procedure in any memory mode")
        await MemoryService.closeAll()
    }

    static func payload(_ answer: JSONValue) -> JSONValue {
        if answer["structuredContent"] != .null { return answer["structuredContent"] }
        guard let text = answer["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return answer }
        return value
    }

    @Test("reconciliation rejects unsupported evidence and caller permissions without clearing quarantine or acting",
          arguments: ["self", "old", "resource", "opposite", "foreign", "observe", "unknown", "extra", "wrong-type", "legacy"])
    func recoveryRejectsUnsupportedEvidenceAndAuthority(_ scenario: String) async throws {
        let knowledge = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let adapter = RemindersFake()
        let writer = Self.tools(knowledge, adapter)
        let readArguments: JSONValue = .object(["name": .string("reminders.find_reminders"), "arguments": .object([:])])
        let oldRead = try await writer.call("call", readArguments)
        let oldEvidence = try #require(oldRead["structuredContent"]["recorded_call"].string)
        _ = try await Self.complete(writer, "r-1")
        let memory = MemoryService.shared(for: knowledge)
        let blocked = try #require(try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil).first)
        if scenario == "resource" { adapter.readID = "r-2" }
        if scenario == "opposite" { adapter.readCompleted = false }
        let read = try await writer.call("call", readArguments)
        let laterEvidence = try #require(read["structuredContent"]["recorded_call"].string)
        var arguments: [String: JSONValue] = ["call": .string(blocked.eventID), "finding": .string("happened"),
                                             "evidence": .string(laterEvidence)]
        if scenario == "self" { arguments["evidence"] = .string(blocked.eventID) }
        if scenario == "old" { arguments["evidence"] = .string(oldEvidence) }
        if scenario == "unknown" { arguments["finding"] = .string("unknown") }
        if scenario == "extra" { arguments["kind"] = .string("acknowledged") }
        if scenario == "wrong-type" { arguments["note"] = .number(1) }
        let profile: SessionProfile
        if scenario == "observe" {
            profile = SessionProfile(attendance: .app, level: .observe, memory: .readLearn,
                catalogue: .open, takeover: false, options: .init(), name: "observer")
        } else { profile = .app }
        let caller = Self.tools(knowledge, adapter, profile: profile)
        if scenario == "foreign" { caller.producer = CallProducer(source: .mcp, streamID: "other-client", traceID: "foreign-recovery") }
        let trace = try #require(writer.producer.traceID)
        let callsBefore = try await memory.calls(inTrace: trace).count
        if scenario == "legacy" {
            await #expect(throws: AutomationFailure.self) {
                try await caller.call("memory_task", .object(["operation": .string("reconcile")]))
            }
        } else {
            await #expect(throws: AutomationFailure.self) {
                try await caller.call("call", .object(["name": .string("reconcile_call"), "arguments": .object(arguments)]))
            }
        }
        #expect(try await memory.perform { try await $0.facts.reconciliations(of: blocked.eventID) }.isEmpty)
        #expect(try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil).contains { $0.eventID == blocked.eventID })
        #expect(try await memory.calls(inTrace: trace).count == callsBefore)
        await #expect(throws: AutomationFailure.self) { _ = try await Self.complete(writer, "r-1") }
        #expect(adapter.completed == 1, "Neither rejected recovery nor repeat sends another write")
        await MemoryService.closeAll()
    }

    static func lastCall(_ memory: MemoryService, verb: String, trace: String) async throws -> String? {
        try await memory.calls(inTrace: trace).last { call in
            guard case .appCall(_, let calledVerb, _) = call.request else { return false }
            return calledVerb == verb
        }?.event.eventID
    }

    @Test("a started call whose process ended gets executor_terminated from the next sweep; one still running is left")
    func sweepOfEndedExecutors() async throws {
        let knowledge = CallDispatchRecordTests.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let memory = MemoryService.shared(for: knowledge)
        let current = try #require(try await MemoryExecutor.current(memory: memory, source: .app))
        // Two earlier processes: one ended (its lock file free), one whose lock this test holds.
        let folder = MemoryExecutor.lockFolder(of: knowledge)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let endedRecord = try await memory.perform {
            try await $0.facts.allocateExecutor(source: "app", processID: 1, startedAtMS: 1)
        }
        let aliveRecord = try await memory.perform {
            try await $0.facts.allocateExecutor(source: "app", processID: 2, startedAtMS: 1)
        }
        FileManager.default.createFile(atPath: folder.appending(path: AppClaims.fileName(of: endedRecord.executorID)).path, contents: Data())
        guard case .success(let held) = AppClaims.lock(aliveRecord.executorID, in: folder) else { Issue.record("no lock"); return }
        defer { close(held) }
        let recorder = { (executor: ExecutorRecord, id: String) async throws in
            let context = ActionContext(source: .app, streamID: "sweep", traceID: "sweep")
            let call = try AgentCallRecord(event: context.event(app: nil, occurredAtMS: 1, monotonicNS: 1),
                                           request: .appCall(app: "reminders", verb: "complete_reminder", arguments: "{\"id\":\"\(id)\"}"))
            var opening = try OperationOpening(call: call, startedAtMS: 1)
            opening.executor = executor
            let opened = opening
            _ = try await memory.perform { try await $0.facts.open(opened) }
            return call.event.eventID
        }
        let ended = try await recorder(endedRecord, "a"), alive = try await recorder(aliveRecord, "b")
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
        _ = try await tools.call("call", .object(["name": .string("status"), "arguments": .object([:])]))
        let calls=try await memory.calls(inTrace: "audit-status")
        let status=try #require(calls.first {$0.request.tool == .status})
        await #expect(throws: OperationFactError.self) {
            try await memory.reconcile(CallReconciliation(
                callEventID: uncertain.eventID, kind: .observed, finding: .notHappened,
                evidenceEventID: status.event.eventID, declaredBy: .agent, recordedAtMS: memory.clock.calendarMS()))
        }
        let left=try await memory.unresolvedCalls(source: .app, streamID: "audit-status", excludingExecutor: nil)
        #expect(left.contains {$0.eventID == uncertain.eventID}, "uncertain mutation was cleared by an unrelated status")
        // Simulate an invalid observation already written by the previous build; it must stay historical without resolving.
        let legacy = try SQLiteConnection(path: memory.url.path)
        let insertion = try legacy.prepare("""
            INSERT INTO memory_call_reconciliations
            (event_id, sequence, kind, finding, evidence_event_id, declared_by, recorded_at_ms)
            VALUES (?, 1, 'observed', 'not_happened', ?, 'agent', 1)
            """)
        try insertion.bind([try SQLiteRowIdentity(legacy).key(.event, uncertain.eventID),
                            try SQLiteRowIdentity(legacy).key(.event, status.event.eventID)])
        _ = try insertion.step()
        insertion.finalize()
        legacy.close()
        let historical = try await memory.unresolvedCalls(source: .app, streamID: "audit-status", excludingExecutor: nil)
        #expect(historical.contains { $0.eventID == uncertain.eventID })
        #expect(try await memory.perform { try await $0.facts.reconciliations(of: uncertain.eventID) }.count == 1)
        _ = try await tools.call("end", .object(["outcome": .string("completed")]))
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
        func readAndReconcile(_ finding: CallReconciliation.Finding) async throws {
            _ = try await tools.call("call", .object(["name": .string("reminders.find_reminders"), "arguments": .object([:])]))
            let evidenceTrace = try #require(tools.producer.traceID)
            let evidence = try #require(try await Self.lastCall(memory, verb: "find_reminders", trace: evidenceTrace))
            try await memory.reconcile(CallReconciliation(
                callEventID: call.eventID, kind: .observed, finding: finding,
                evidenceEventID: evidence, declaredBy: .agent, recordedAtMS: memory.clock.calendarMS()))
        }
        adapter.readID = "another-reminder"
        await #expect(throws: OperationFactError.self) { try await readAndReconcile(.happened) }
        adapter.readID = "r-1"
        adapter.readCompleted = false
        await #expect(throws: OperationFactError.self) { try await readAndReconcile(.happened) }
        let originalProducer = tools.producer
        tools.producer = CallProducer(source: .app, streamID: "foreign", traceID: "foreign")
        await #expect(throws: OperationFactError.self) { try await readAndReconcile(.notHappened) }
        tools.producer = originalProducer
        try await readAndReconcile(.notHappened)
        #expect(try await memory.unresolvedCalls(source: .app, streamID: "p206", excludingExecutor: nil).isEmpty)
        #expect(try await memory.perform { try await $0.facts.effect(of: call.eventID) }?.performed == .uncertain)
        _ = try await tools.call("end", .object(["outcome": .string("completed")]))
        await MemoryService.closeAll()
    }

}
