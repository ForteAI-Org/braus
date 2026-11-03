//
//  TaskAttributionRepositoryTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// Verifications as facts with their attribution apart, and episodes, memberships and labels as
/// stated: applied once, updated only against the record last read, refused on conflicts and on
/// rows the contract does not admit, and written together all or nothing.
@Suite("Verifications and explicit task attributions", .serialized)
struct TaskAttributionRepositoryTests {

    private typealias F = AttributionFixtures

    private func episode(_ id: String = "t1", ended: Int64? = nil, status: TaskStatus = .observed, trace: String? = "trace-1") throws -> TaskOccurrenceRecord {
        try TaskOccurrenceRecord(taskOccurrenceID: id, traceID: trace, startedAtMS: F.t0, endedAtMS: ended, status: status)
    }

    private func label(_ id: String, _ text: String = "Rispondere a Zoë", confidence: Double? = 0.4, status: TaskLabelStatus = .candidate,
                       at ms: Int64 = F.t0 + 1_000, task: String = "t1") throws -> TaskLabelRecord {
        try TaskLabelRecord(labelID: id, taskOccurrenceID: task, label: text, assignedBy: "fixture", confidence: confidence, status: status, assignedAtMS: ms)
    }

    @Test("a verification is a fact: its three verdicts kept as stated, retried already applied, other facts a conflict; its attribution to a step occurrence is apart, once, and never fails the fact's retry")
    func verifications() async throws {
        let memory = try await F.open22()
        let verdicts: [(String, VerificationVerdict, String?, String?)] = [("v-unknown", .unknown, nil, nil), ("v-passed", .passed, "Inviato", "Inviato"),
                                                                           ("v-failed", .failed, "Café", "Cafe\u{301}")]
        for (id, verdict, expected, observed) in verdicts {
            let record = try VerificationRecord(event: F.verificationEvent(id), scope: .call, method: .sceneText, verdict: verdict,
                                                expectedText: expected, observedText: observed)
            #expect(try await memory.verifications.record(record) == .committed)
            #expect(try await memory.verifications.record(record) == .alreadyApplied)
        }
        let raw = try await memory.store.read { try $0.query("SELECT (SELECT event_uuid FROM memory_events e WHERE e.event_id=memory_verifications.event_id), verdict, hex(expected_text), hex(observed_text), step_occurrence_id IS NULL FROM memory_verifications ORDER BY (SELECT event_uuid FROM memory_events e WHERE e.event_id=memory_verifications.event_id)", []) {
            "\(try $0.text(0) ?? "") \(try $0.text(1) ?? "") \(try $0.text(2) ?? "") \(try $0.text(3) ?? "") \($0.integer(4) ?? -1)" } }
        #expect(raw == ["v-failed failed 436166C3A9 43616665CC81 1", "v-passed passed 496E766961746F 496E766961746F 1", "v-unknown unknown   1"],
                "the texts are the bytes given, composed and decomposed apart, absent as NULL, and no attribution yet")
        let unknown = try VerificationRecord(event: F.verificationEvent("v-unknown"), scope: .call, method: .sceneText, verdict: .unknown)
        for other in [try VerificationRecord(event: F.verificationEvent("v-unknown"), scope: .call, method: .sceneText, verdict: .passed),
                      try VerificationRecord(event: F.verificationEvent("v-unknown"), scope: .step, method: .sceneText, verdict: .unknown),
                      try VerificationRecord(event: F.verificationEvent("v-unknown"), scope: .call, method: .sceneText, verdict: .unknown, expectedText: "")] {
            let error = await storeError { _ = try await memory.verifications.record(other) }
            guard case .identity? = error else {
                Issue.record("expected a conflict, got \(String(describing: error))")
                continue
            }
        }
        let steps = SQLiteStepOccurrenceRepository(store: memory.store)
        let step1 = try await steps.insert(StepOccurrenceRecord(stepOccurrenceID: "so-1", startedAtMS: 0, status: .observed)).occurrence.stepOccurrenceID
        let step2 = try await steps.insert(StepOccurrenceRecord(stepOccurrenceID: "so-2", startedAtMS: 0, status: .observed)).occurrence.stepOccurrenceID
        #expect(try await memory.verifications.attribute(verification: "v-passed", toStepOccurrence: step1) == .committed)
        #expect(try await memory.verifications.attribute(verification: "v-passed", toStepOccurrence: step1) == .alreadyApplied)
        #expect(await factError { _ = try await memory.verifications.attribute(verification: "v-passed", toStepOccurrence: step2) } == .alreadyAttributed(eventID: "v-passed"))
        #expect(await factError { _ = try await memory.verifications.attribute(verification: "v-unknown", toStepOccurrence: "so-9") } == .missingOccurrence(id: "so-9"))
        #expect(await factError { _ = try await memory.verifications.attribute(verification: "v-none", toStepOccurrence: step1) } == .missingEvent(eventID: "v-none"))
        let passed = try VerificationRecord(event: F.verificationEvent("v-passed"), scope: .call, method: .sceneText, verdict: .passed,
                                            expectedText: "Inviato", observedText: "Inviato")
        #expect(try await memory.verifications.record(passed) == .alreadyApplied, "the attribution is not part of the fact")
        #expect(try await memory.verifications.verification("v-passed")?.stepOccurrenceID == step1)
        // References written by hand: a verification membership agreeing with the attribution is kept;
        // coherence refusals for other occurrences are covered by DB2BSchemaCoherenceTests.
        try await memory.plant([("INSERT INTO memory_step_events (step_occurrence_id, event_id, position, role) VALUES ('\(step1)', (SELECT event_id FROM memory_events WHERE event_uuid='v-passed'), 0, 'verification')", [])])
        #expect(try await memory.verifications.attribute(verification: "v-passed", toStepOccurrence: step1) == .alreadyApplied, "the reference stays valid")
        #expect(try await memory.verifications.verification("v-unknown")?.record.verdict == .unknown, "unknown stays unknown")
        #expect(try await memory.verifications.verification("v-unknown")?.stepOccurrenceID == nil)
        _ = try await memory.captures.record(F.verificationEvent("v-bad"))
        try await memory.plant([("INSERT INTO memory_verifications (event_id, scope, method, verdict) VALUES ((SELECT event_id FROM memory_events WHERE event_uuid='v-bad'), 'route', 'scene_text', 'passed')", [])])
        #expect(await factError { _ = try await memory.verifications.verification("v-bad") }
                == .malformedRow(table: "memory_verifications", id: "v-bad", malformation: .unknownCode(column: "scope", code: "route")))
        #expect(try await memory.verifications.record(unknown) == .alreadyApplied, "the store goes on")
        await memory.store.close()
    }

    @Test("an episode is recorded once, changed only against the record last read, and never in its id, trace or start; an absent end stays absent")
    func episodes() async throws {
        let memory = try await F.open22()
        let v0 = try episode()
        #expect(try await memory.tasks.record(v0) == .committed)
        #expect(try await memory.tasks.record(v0) == .alreadyApplied)
        #expect(try await memory.tasks.occurrence("t1")?.endedAtMS == nil)
        let conflict = await storeError { _ = try await memory.tasks.record(try episode(status: .inProgress)) }
        guard case .identity? = conflict else {
            Issue.record("expected a conflict, got \(String(describing: conflict))")
            return
        }
        let v1 = try episode(ended: F.t0 + 9_000, status: .completed)
        #expect(try await memory.tasks.update(from: v0, to: v1) == .committed)
        #expect(try await memory.tasks.update(from: v0, to: v1) == .alreadyApplied)
        #expect(await factError { _ = try await memory.tasks.update(from: v0, to: try episode(status: .failed)) } == .staleExpectation(id: "t1"))
        #expect(await factError { _ = try await memory.tasks.update(from: v1, to: try episode(trace: nil)) } == .immutableField(id: "t1", field: "trace_id"))
        #expect(await factError {
            _ = try await memory.tasks.update(from: v1, to: try TaskOccurrenceRecord(taskOccurrenceID: "t1", traceID: "trace-1", startedAtMS: 0, status: .completed))
        } == .immutableField(id: "t1", field: "started_at_ms"))
        #expect(await factError { _ = try await memory.tasks.update(from: try episode("t9"), to: try episode("t9")) } == .missingOccurrence(id: "t9"))
        #expect(try await memory.tasks.occurrence("t1")?.isExactly(v1) == true)
        try await memory.plant([("INSERT INTO memory_task_occurrences (task_occurrence_uuid, started_at_ms, status) VALUES ('t-far', ?, 'observed')", [.integer(1 << 60)])])
        #expect(await factError { _ = try await memory.tasks.occurrence("t-far") }
                == .malformedRow(table: "memory_task_occurrences", id: "t-far", malformation: .invalid(.outOfRange(field: "ms"))))
        await memory.store.close()
    }

    @Test("two stores updating one episode from the same read: one commits, the other is stale and commits after reading again")
    func twoStores() async throws {
        let first = try await F.open22()
        let second = try await F.open22(at: first.url)
        let v0 = try episode()
        _ = try await first.tasks.record(v0)
        func attempt(_ memory: F.Memory, _ to: TaskOccurrenceRecord) async -> EventFactError? {
            await factError { _ = try await memory.tasks.update(from: v0, to: to) }
        }
        let a = try episode(status: .inProgress), b = try episode(ended: F.t0 + 5, status: .cancelled)
        async let left = attempt(first, a)
        async let right = attempt(second, b)
        let outcomes = await [left, right]
        #expect(outcomes.filter { $0 == nil }.count == 1 && outcomes.filter { $0 == .staleExpectation(id: "t1") }.count == 1)
        let winner = try #require(try await second.tasks.occurrence("t1"))
        #expect(winner.isExactly(a) || winner.isExactly(b))
        #expect(try await second.tasks.update(from: winner, to: try episode(ended: F.t0 + 7, status: .interrupted)) == .committed)
        await second.store.close()
        await first.store.close()
    }

    @Test("memberships place stored events once by episode, event and role; a position another attribution holds is taken; the role need not be the event's kind; the events stay as they were; labels are kept side by side, none chosen")
    func membershipsAndLabels() async throws {
        let memory = try await F.open22()
        _ = try await memory.tasks.record(try episode())
        _ = try await memory.calls.record(try F.agentCall("a1"))
        _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w1", at: F.t0 + 1, app: AppContextIdentity(bundleID: "test.other")),
                                                                   input: try F.click()))
        let events = try await memory.count("SELECT count(*) FROM memory_events")
        let action = try TaskMembership(taskOccurrenceID: "t1", eventID: "a1", position: 0, role: .action)
        let context = try TaskMembership(taskOccurrenceID: "t1", eventID: "w1", position: 1, role: .context)
        #expect(try await memory.tasks.record(action) == .committed)
        #expect(try await memory.tasks.record(context) == .committed, "another application's event in the same episode")
        #expect(try await memory.tasks.record(action) == .alreadyApplied)
        let moved = await storeError { _ = try await memory.tasks.record(try TaskMembership(taskOccurrenceID: "t1", eventID: "a1", position: 5, role: .action)) }
        guard case .identity? = moved else {
            Issue.record("the same membership at another position must be a conflict, got \(String(describing: moved))")
            return
        }
        #expect(await factError { _ = try await memory.tasks.record(try TaskMembership(taskOccurrenceID: "t1", eventID: "a1", position: 1, role: .observation)) }
                == .positionTaken(taskOccurrenceID: "t1", position: 1))
        #expect(try await memory.tasks.record(try TaskMembership(taskOccurrenceID: "t1", eventID: "a1", position: 2, role: .observation)) == .committed,
                "one event under a second role, at its own position")
        #expect(await factError { _ = try await memory.tasks.record(try TaskMembership(taskOccurrenceID: "t1", eventID: "nobody", position: 3, role: .context)) }
                == .missingEvent(eventID: "nobody"))
        #expect(await factError { _ = try await memory.tasks.record(try TaskMembership(taskOccurrenceID: "t9", eventID: "a1", position: 0, role: .action)) }
                == .missingOccurrence(id: "t9"))
        #expect(try await memory.tasks.memberships(of: "t1").map(\.position) == [0, 1, 2])
        #expect(try await memory.count("SELECT count(*) FROM memory_events") == events, "no event is made up or changed")

        let insertedFirst = try await memory.tasks.insert(label("l1", confidence: nil, at: F.t0 + 2_000))
        let insertedSecond = try await memory.tasks.insert(label("l2", "Rispondere a Zoe\u{308}", confidence: 0.9, status: .confirmed, at: F.t0 + 1_500))
        let first = insertedFirst.label, second = insertedSecond.label
        #expect(insertedFirst.receipt == .committed)
        #expect(insertedSecond.receipt == .committed)
        #expect(try await memory.tasks.record(first) == .alreadyApplied)
        let relabelled = await storeError { _ = try await memory.tasks.record(try label(first.labelID, confidence: 0, at: F.t0 + 2_000)) }
        guard case .identity? = relabelled else {
            Issue.record("a label id offered with other content must be a conflict, got \(String(describing: relabelled))")
            return
        }
        let labels = try await memory.tasks.labels(of: "t1")
        #expect(labels.map(\.labelID) == [second.labelID, first.labelID], "by assignment instant; both kept, none chosen")
        #expect(labels[1].confidence == nil, "no confidence stays no confidence")
        #expect(Array(labels[0].label.utf8) == Array("Rispondere a Zoe\u{308}".utf8))
        let farID = try await memory.store.write { transaction in
            try transaction.execute("INSERT INTO memory_task_labels(task_occurrence_id,label,assigned_by,status,assigned_at_ms) VALUES ((SELECT task_occurrence_id FROM memory_task_occurrences WHERE task_occurrence_uuid='t1'),'x','y','candidate',?)", [.integer(1 << 60)])
            return String(try SQLiteIdentityRows.lastInsertedRow(transaction))
        }
        #expect(await factError { _ = try await memory.tasks.labels(of: "t1") }
                == .malformedRow(table: "memory_task_labels", id: farID, malformation: .invalid(.outOfRange(field: "ms"))))
        await memory.store.close()
    }

    @Test("an episode, its memberships and its labels are written together: a last membership that cannot be written leaves no episode, membership or label; offered again whole it is already applied")
    func compositeAttribution() async throws {
        let memory = try await F.open22()
        _ = try await memory.calls.record(try F.agentCall("a1"))
        _ = try await memory.inputs.record(try ObservedInputRecord(event: F.watcherEvent("w1"), input: try F.click()))
        let before = try await memory.ledger()
        let broken = try TaskAttribution(occurrence: try episode("t2"), memberships: [
            try TaskMembership(taskOccurrenceID: "t2", eventID: "w1", position: 0, role: .observation),
            try TaskMembership(taskOccurrenceID: "t2", eventID: "missing", position: 1, role: .action),
        ], labels: [try label("l1", task: "t2")])
        #expect(await factError { _ = try await memory.tasks.attribute(broken) } == .missingEvent(eventID: "missing"))
        #expect(try await memory.ledger() == before, "nothing of the refused attribution remains")
        let whole = try TaskAttribution(occurrence: try episode("t2"), memberships: [
            try TaskMembership(taskOccurrenceID: "t2", eventID: "w1", position: 0, role: .observation),
            try TaskMembership(taskOccurrenceID: "t2", eventID: "a1", position: 1, role: .action),
        ], labels: [try label("l1", task: "t2")])
        #expect(try await memory.tasks.attribute(whole) == .committed)
        let storedWhole = try TaskAttribution(occurrence: whole.occurrence, memberships: whole.memberships,
                                              labels: try await memory.tasks.labels(of: "t2"))
        #expect(try await memory.tasks.attribute(storedWhole) == .alreadyApplied)
        #expect(try await memory.tasks.memberships(of: "t2").map(\.eventID) == ["w1", "a1"])
        await memory.store.close()
    }
}
