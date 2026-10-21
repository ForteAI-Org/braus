//
//  OperationFactRepositoryTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// OperationFactRepositoryTests prove the essential writes of a call on a real archive: the opening
/// before the effect with its task attribution, the conclusion after it with samples, effect and
/// typed verification in one transaction, retries that add nothing, conflicts that write nothing,
/// and the declared gaps of withheld values.
@Suite("The essential facts of a call: opening, conclusion, verification and declared gaps")
struct OperationFactRepositoryTests {

    static let app = AgentCallFixtures.app

    static func event(_ id: String, kind: MemoryEventKind = .action) -> MemoryEventRecord {
        MemoryEventRecord(
            eventID: id,
            source: .app,
            streamID: "worker-1",
            traceID: "message-1",
            sessionID: AgentCallFixtures.session,
            kind: kind,
            app: app,
            occurredAtMS: TaskFixtures.t0
        )
    }

    static func click(_ id: String) throws -> AgentCallRecord {
        try AgentCallRecord(event: event(id), request: .act(target: "Export", verb: .click, value: nil, section: nil))
    }

    static func sample(_ id: String, _ phase: CapturePhase, labels: [String] = ["Export", "Cancel"]) -> CaptureSample {
        SceneFixtures.sample(id, phase: phase, of: SceneFixtures.pixelsOnly(labels))
    }

    static func verification(
        _ call: String,
        _ check: OperationCheck,
        samples: [CaptureSampleKey]
    ) throws -> OperationVerification {
        let id = OperationVerification.eventID(call: call, condition: check.condition)
        return try OperationVerification(
            event: event(id, kind: .verification),
            callEventID: call,
            check: check,
            samples: samples
        )
    }

    static func conclusion(_ call: String, verdict: OperationCheck.Verdict = .passed) throws -> OperationConclusion {
        let check = OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: verdict,
            expected: "menuOpened",
            observed: "menuOpened",
            limits: [.windowWide],
            performed: .requested,
            target: OperationCheck.Target(elementID: "control|export", role: "AXButton", label: "Export", section: nil)
        )
        let before = sample(call, .before), after = sample(call, .after, labels: ["PNG", "JPEG", "TIFF"])
        return try OperationConclusion(
            end: AgentCallTransition(
                call,
                AgentCallProgress(
                    .completed,
                    result: .outcome(.foundActed, message: "clicked 'Export'"),
                    endedAtMS: TaskFixtures.t0 + 30,
                    durationMS: 30
                )
            ),
            samples: [before, after],
            effect: try OperationEffect(callEventID: call, performed: .requested, target: check.target, checked: true),
            verifications: [try verification(call, check, samples: [before.key, after.key])]
        )
    }

    @Test("a call opened with its task attribution and concluded with samples, effect and verification reads back whole; offered again, nothing moves")
    func openAndConclude() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        let opening = try OperationOpening(
            call: try Self.click("c1"),
            startedAtMS: TaskFixtures.t0 + 1,
            attribution: attribution
        )
        #expect(try await memory.facts.open(opening) == .committed)
        #expect(try await memory.facts.open(opening) == .alreadyApplied)
        #expect(try await memory.calls.call("c1")?.progress.status == .started)
        let conclusion = try Self.conclusion("c1")
        #expect(try await memory.facts.conclude(conclusion) == .committed)
        #expect(try await memory.facts.conclude(conclusion) == .alreadyApplied, "a retried conclusion is the same fact")
        #expect(try await memory.count("SELECT count(*) FROM memory_operation_verifications") == 1)

        #expect(try await memory.calls.call("c1")?.progress.status == .completed)
        let effect = try #require(try await memory.facts.effect(of: "c1"))
        #expect(effect.performed == .requested && effect.checked && effect.target?.label == "Export")
        let verifications = try await memory.facts.verifications(of: "c1")
        #expect(verifications.count == 1)
        let read = try #require(verifications.first)
        #expect(read.check == conclusion.verifications[0].check,
                "condition, method, verdict, texts, limits and target as given")
        #expect(read.samples.map(\.phase) == [.before, .after])
        #expect(read.event.kind == .verification && read.event.traceID == "message-1")
        let stored = try #require(
            try await SQLiteVerificationRepository(store: memory.store).verification(read.event.eventID)
        )
        #expect(stored.record.scope == .call && stored.record.method == .sceneDifference
                && stored.record.verdict == .passed)
        #expect(try await memory.facts.attribution(of: "c1") == attribution)
        #expect(try await memory.tasks.calls(of: "attempt-1", for: TaskFixtures.producer) == ["c1"])
        await memory.store.close()
    }

    @Test("an unknown verdict stays unknown with its limits; a call with no check reports an explicit gap, never a pass")
    func unknownStaysUnknown() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c2"), startedAtMS: TaskFixtures.t0 + 1)
        )
        let unknown = OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: .unknown,
            limits: [.unattributed, .noExpectation],
            performed: .requested
        )
        let conclusion = try OperationConclusion(
            end: AgentCallTransition(
                "c2",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.actedUnverified, message: "no change"),
                    endedAtMS: TaskFixtures.t0 + 2
                )
            ),
            effect: try OperationEffect(callEventID: "c2", performed: .requested, checked: true),
            verifications: [try Self.verification("c2", unknown, samples: [])]
        )
        _ = try await memory.facts.conclude(conclusion)
        let read = try #require(try await memory.facts.verifications(of: "c2").first)
        #expect(read.check.verdict == .unknown && read.check.limits == [.unattributed, .noExpectation])

        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c3"), startedAtMS: TaskFixtures.t0 + 3)
        )
        _ = try await memory.facts.conclude(try OperationConclusion(
            end: AgentCallTransition(
                "c3",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.actedUnverified, message: "?"),
                    endedAtMS: TaskFixtures.t0 + 4
                )
            ),
            effect: try OperationEffect(callEventID: "c3", performed: .requested, checked: false)
        ))
        #expect(try await memory.facts.effect(of: "c3")?.checked == false)
        #expect(try await memory.facts.verifications(of: "c3").isEmpty)
        await memory.store.close()
    }

    @Test("M05: a call's route is written with its end and reads back; offered again nothing moves, another is a conflict; the table refuses a route it does not name, a reason off the desktop, a change, and a route before the call's end")
    func routeWithTheEnd() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("c9"), startedAtMS: TaskFixtures.t0 + 1))
        let base = try Self.conclusion("c9")
        func ending(_ route: CallRoute?) throws -> OperationConclusion {
            try OperationConclusion(end: base.end, samples: base.samples, effect: base.effect,
                                    verifications: base.verifications, route: route)
        }
        let handedBack = CallRoute(.desktop, handoffReason: "Notes shows the MacDriver no window it can read.")
        #expect(try await memory.facts.conclude(try ending(handedBack)) == .committed)
        #expect(try await memory.facts.route(of: "c9") == handedBack)
        #expect(try await memory.facts.conclude(try ending(handedBack)) == .alreadyApplied)
        await #expect(throws: (any Error).self) { _ = try await memory.facts.conclude(try ending(CallRoute(.native))) }
        #expect(try await memory.facts.route(of: "c9") == handedBack)

        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("c10"), startedAtMS: TaskFixtures.t0 + 2))
        _ = try await memory.facts.conclude(try Self.conclusion("c10"))
        #expect(try await memory.facts.route(of: "c10") == nil, "a call of a session that is not routed has none")
        for (route, reason) in [("seat", "NULL"), ("native", "'given back'"), ("desktop", "''")] {
            await #expect(throws: (any Error).self) {
                try await memory.store.write { transaction in
                    try transaction.execute("INSERT INTO memory_call_routes (event_id, route, handoff_reason) "
                                            + "VALUES ('c10', '\(route)', \(reason))")
                }
            }
        }
        // Written once, with the end: never changed, never on a call still running.
        await #expect(throws: (any Error).self) {
            try await memory.store.write { transaction in
                try transaction.execute("UPDATE memory_call_routes SET handoff_reason = 'another' WHERE event_id = 'c9'")
            }
        }
        #expect(try await memory.facts.route(of: "c9") == handedBack)
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("c11"), startedAtMS: TaskFixtures.t0 + 3))
        await #expect(throws: (any Error).self) {
            try await memory.store.write { transaction in
                try transaction.execute("INSERT INTO memory_call_routes (event_id, route) VALUES ('c11', 'native')")
            }
        }
        #expect(try await memory.facts.route(of: "c11") == nil, "a started call has no route")
        #expect(CallRoute(.native, handoffReason: "given back").handoffReason == nil)
        #expect(CallRoute(.desktop, handoffReason: "").handoffReason == CallRoute.noReason)
        await memory.store.close()
    }

    @Test("M05: a call's route advice is written with its end and reads back, a use with its route or an ask; offered again nothing moves, another is a conflict; a call without one has none; the table refuses a decision it does not name, a use without a route, an ask with one, empty words, and a change")
    func adviceWithTheEnd() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r14"), startedAtMS: TaskFixtures.t0 + 6))
        let base = try Self.conclusion("r14")
        func ending(_ advice: CallRouteAdvice?) throws -> OperationConclusion {
            try OperationConclusion(end: base.end, samples: base.samples, effect: base.effect,
                                    verifications: base.verifications, advice: advice)
        }
        let use = CallRouteAdvice(decision: .use, route: "web:google.com/maps", message: "Maps: use web:google.com/maps instead of the app.")
        #expect(try await memory.facts.conclude(try ending(use)) == .committed)
        #expect(try await memory.facts.advice(of: "r14") == use)
        #expect(try await memory.facts.conclude(try ending(use)) == .alreadyApplied)
        await #expect(throws: (any Error).self) {
            _ = try await memory.facts.conclude(try ending(CallRouteAdvice(decision: .ask, route: nil, message: "which account?")))
        }
        #expect(try await memory.facts.advice(of: "r14") == use)

        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r15"), startedAtMS: TaskFixtures.t0 + 7))
        let ask = CallRouteAdvice(decision: .ask, route: nil, message: "Mail: which account?")
        let fifteenth = try Self.conclusion("r15")
        #expect(try await memory.facts.conclude(try OperationConclusion(
            end: fifteenth.end, samples: fifteenth.samples, effect: fifteenth.effect, verifications: fifteenth.verifications, advice: ask
        )) == .committed)
        #expect(try await memory.facts.advice(of: "r15") == ask)

        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r16"), startedAtMS: TaskFixtures.t0 + 8))
        _ = try await memory.facts.conclude(try Self.conclusion("r16"))
        #expect(try await memory.facts.advice(of: "r16") == nil, "a call that answered no advice has none")
        // The open decision with the router's note: no route, the words kept.
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r18"), startedAtMS: TaskFixtures.t0 + 10))
        let opened = CallRouteAdvice(decision: .open, route: nil, message: "Finder has no files adapter in this build yet: driving its interface.")
        let eighteenth = try Self.conclusion("r18")
        #expect(try await memory.facts.conclude(try OperationConclusion(
            end: eighteenth.end, samples: eighteenth.samples, effect: eighteenth.effect, verifications: eighteenth.verifications, advice: opened
        )) == .committed)
        #expect(try await memory.facts.advice(of: "r18") == opened)
        for (decision, route, message) in [("opened", "NULL", "'opened'"), ("open", "'web:x'", "'note'"), ("open", "NULL", "''"),
                                           ("use", "NULL", "'use'"), ("ask", "'web:x'", "'which?'"), ("ask", "NULL", "''")] {
            await #expect(throws: (any Error).self) {
                try await memory.store.write { transaction in
                    try transaction.execute("INSERT INTO memory_call_route_advice (event_id, decision, route, message) "
                                            + "VALUES ('r16', '\(decision)', \(route), \(message))")
                }
            }
        }
        await #expect(throws: (any Error).self) {
            try await memory.store.write { transaction in
                try transaction.execute("UPDATE memory_call_route_advice SET decision = 'ask', route = NULL WHERE event_id = 'r14'")
            }
        }
        let fourteenthKept = try await memory.facts.advice(of: "r14")
        let sixteenthKept  = try await memory.facts.advice(of: "r16")
        #expect(fourteenthKept == use && sixteenthKept == nil)
        await memory.store.close()
    }

    @Test("M05: an end whose advice the table refuses commits nothing: the call stays started with no sample, effect, verification or advice; the same end with a valid advice then commits once; a different advice offered later is a conflict that keeps every fact")
    func invalidAdviceRollsTheEndBack() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r17"), startedAtMS: TaskFixtures.t0 + 9))
        let base = try Self.conclusion("r17")
        func ending(_ advice: CallRouteAdvice?) throws -> OperationConclusion {
            try OperationConclusion(end: base.end, samples: base.samples, effect: base.effect,
                                    verifications: base.verifications, advice: advice)
        }
        /// The rows the archive holds for r17: its distinct samples (by phase and ordinal; a sample is several
        /// observation rows), effects, verifications, advice.
        func rows() throws -> [Int] {
            let archive = try SQLiteConnection(path: memory.url.path, readOnly: true)
            defer { archive.close() }
            let queries = ["SELECT count(*) FROM (SELECT DISTINCT phase, sample_ordinal FROM memory_event_observations WHERE event_id = 'r17')",
                           "SELECT count(*) FROM memory_call_effects WHERE event_id = 'r17'",
                           "SELECT count(*) FROM memory_operation_verifications WHERE call_event_id = 'r17'",
                           "SELECT count(*) FROM memory_call_route_advice WHERE event_id = 'r17'"]
            return try queries.map { Int(try archive.query($0) { $0.integer(0) ?? 0 }.first ?? -1) }
        }
        let opened = try await memory.calls.call("r17")
        #expect(try rows() == [0, 0, 0, 0] && opened?.progress.status == .started)
        // A use without its route: the table refuses the row, and with it the whole end.
        let invalid = CallRouteAdvice(decision: .use, route: nil, message: "use the web")
        await #expect(throws: (any Error).self) { _ = try await memory.facts.conclude(try ending(invalid)) }
        let stillStarted = try await memory.calls.call("r17")
        #expect(stillStarted?.progress.status == .started, "the end did not advance")
        let noEffect = try await memory.facts.effect(of: "r17")
        let noVerifications = try await memory.facts.verifications(of: "r17")
        let noAdvice = try await memory.facts.advice(of: "r17")
        #expect(noEffect == nil && noVerifications.isEmpty && noAdvice == nil)
        #expect(try rows() == [0, 0, 0, 0], "nothing of the refused end was kept")
        // The same end with a valid advice commits once.
        let valid = CallRouteAdvice(decision: .use, route: "web:google.com/maps", message: "Maps: use web:google.com/maps instead of the app.")
        #expect(try await memory.facts.conclude(try ending(valid)) == .committed)
        let completed = try await memory.calls.call("r17")
        #expect(completed?.progress.status == .completed)
        let kept = try rows()
        #expect(kept[0] == base.samples.count && kept[1] == 1 && kept[2] == base.verifications.count && kept[3] == 1, "\(kept)")
        #expect(try await memory.facts.conclude(try ending(valid)) == .alreadyApplied)
        #expect(try rows() == kept)
        // Another advice for the same end: a conflict, and every fact as it was.
        await #expect(throws: (any Error).self) {
            _ = try await memory.facts.conclude(try ending(CallRouteAdvice(decision: .ask, route: nil, message: "which account?")))
        }
        let adviceKept = try await memory.facts.advice(of: "r17")
        let effectKept = try await memory.facts.effect(of: "r17")
        let callKept   = try await memory.calls.call("r17")
        #expect(try rows() == kept && adviceKept == valid && effectKept != nil && callKept?.progress.status == .completed)
        await memory.store.close()
    }

    @Test("M05: a call's rung is written with its end and reads back, its skipped reasons whole; offered again nothing moves, another is a conflict; the table refuses a rung it does not name, an empty how or reason, a change, and a rung before the call's end")
    func rungWithTheEnd() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r9"), startedAtMS: TaskFixtures.t0 + 1))
        let base = try Self.conclusion("r9")
        func ending(_ rung: CallRung?) throws -> OperationConclusion {
            try OperationConclusion(end: base.end, samples: base.samples, effect: base.effect,
                                    verifications: base.verifications, rung: rung)
        }
        let posted = CallRung(rung: .inPlace, how: "events to the process",
                              skipped: ["element has no AXPress", "keys have no accessibility action: posted to the process"])
        #expect(try await memory.facts.conclude(try ending(posted)) == .committed)
        #expect(try await memory.facts.rung(of: "r9") == posted)
        #expect(try await memory.facts.conclude(try ending(posted)) == .alreadyApplied)
        await #expect(throws: (any Error).self) {
            _ = try await memory.facts.conclude(try ending(CallRung(rung: .accessibility, how: "pressed AXButton")))
        }
        #expect(try await memory.facts.rung(of: "r9") == posted)

        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r10"), startedAtMS: TaskFixtures.t0 + 2))
        _ = try await memory.facts.conclude(try Self.conclusion("r10"))
        #expect(try await memory.facts.rung(of: "r10") == nil, "a call that sent no gesture of the MacDriver's has none")
        for (rung, how, skipped) in [("menu", "'pressed'", "NULL"), ("accessibility", "''", "NULL"), ("in_place", "'events'", "''")] {
            await #expect(throws: (any Error).self) {
                try await memory.store.write { transaction in
                    try transaction.execute("INSERT INTO memory_call_rungs (event_id, rung, how, skipped) "
                                            + "VALUES ('r10', '\(rung)', \(how), \(skipped))")
                }
            }
        }
        await #expect(throws: (any Error).self) {
            try await memory.store.write { transaction in
                try transaction.execute("UPDATE memory_call_rungs SET how = 'another' WHERE event_id = 'r9'")
            }
        }
        #expect(try await memory.facts.rung(of: "r9") == posted)
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r11"), startedAtMS: TaskFixtures.t0 + 3))
        await #expect(throws: (any Error).self) {
            try await memory.store.write { transaction in
                try transaction.execute("INSERT INTO memory_call_rungs (event_id, rung, how) VALUES ('r11', 'accessibility', 'pressed')")
            }
        }
        #expect(try await memory.facts.rung(of: "r11") == nil, "a started call has no rung")
        #expect(CallRung(rung: .accessibility, how: "focused AXTextField", skipped: [""]).skipped.isEmpty, "an empty reason is none")
        // The Seat's rungs, by the receipt's posting call, with the send's counts and nothing skipped.
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r12"), startedAtMS: TaskFixtures.t0 + 4))
        let seat = CallRung(rung: .seatAccessibilityAction, how: "0 events, 0 routed to window 7")
        let twelfth = try Self.conclusion("r12")
        #expect(try await memory.facts.conclude(try OperationConclusion(
            end: twelfth.end, samples: twelfth.samples, effect: twelfth.effect, verifications: twelfth.verifications, rung: seat
        )) == .committed)
        #expect(try await memory.facts.rung(of: "r12") == seat)
        // The web's rung: the Input method, the counts and the outcome as how, nothing skipped.
        _ = try await memory.facts.open(try OperationOpening(call: try Self.click("r13"), startedAtMS: TaskFixtures.t0 + 5))
        let web = CallRung(rung: .webInputEvent, how: "Input.dispatchMouseEvent: 3 planned, 2 attempted, 1 acknowledged, rejected by the browser")
        let thirteenth = try Self.conclusion("r13")
        #expect(try await memory.facts.conclude(try OperationConclusion(
            end: thirteenth.end, samples: thirteenth.samples, effect: thirteenth.effect, verifications: thirteenth.verifications, rung: web
        )) == .committed)
        #expect(try await memory.facts.rung(of: "r13") == web)
        await memory.store.close()
    }

    @Test("another end, effect or verification under a stored identity is a conflict, and the whole conclusion writes nothing")
    func conflictsWriteNothing() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c4"), startedAtMS: TaskFixtures.t0 + 1)
        )
        _ = try await memory.facts.conclude(try Self.conclusion("c4", verdict: .passed))
        let before = try await memory.count("SELECT count(*) FROM memory_event_observations")
        await #expect(throws: (any Error).self) {
            _ = try await memory.facts.conclude(try Self.conclusion("c4", verdict: .failed))
        }
        #expect(try await memory.count("SELECT count(*) FROM memory_event_observations") == before)
        #expect(try await memory.facts.verifications(of: "c4").first?.check.verdict == .passed)
        await memory.store.close()
    }

    @Test("a call attributed to an attempt that is no longer running is refused before anything is written")
    func attributionNeedsRunningAttempt() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        _ = try await memory.tasks.checkpoint(
            try TaskCheckpointDraft(kind: .end, declared: .completed),
            attempt: "attempt-1",
            at: TaskFixtures.t0 + 1,
            by: TaskFixtures.producer
        )
        let late = try OperationOpening(
            call: try Self.click("c5"),
            startedAtMS: TaskFixtures.t0 + 2,
            attribution: try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        )
        await #expect(throws: OperationFactError.attemptNotRunning(attemptID: "attempt-1")) {
            _ = try await memory.facts.open(late)
        }
        #expect(try await memory.calls.call("c5") == nil, "the call was not written: no gesture may follow")
        await memory.store.close()
    }

    @Test("a verification that names a sample the conclusion did not bring and the archive does not hold is refused whole")
    func verificationNeedsItsSamples() async throws {
        let memory = try await TaskFixtures.open()
        _ = try await memory.facts.open(
            try OperationOpening(call: try Self.click("c6"), startedAtMS: TaskFixtures.t0 + 1)
        )
        let check = OperationCheck(
            condition: .structuralEffect,
            method: .sceneDifference,
            verdict: .passed,
            performed: .requested
        )
        let missing = CaptureSampleKey(eventID: "c6", phase: .after)
        let conclusion = try OperationConclusion(
            end: AgentCallTransition(
                "c6",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.foundActed, message: "ok"),
                    endedAtMS: TaskFixtures.t0 + 2
                )
            ),
            verifications: [try Self.verification("c6", check, samples: [missing])]
        )
        await #expect(throws: AgentCallError.missingSample(eventID: "c6", sample: missing)) {
            _ = try await memory.facts.conclude(conclusion)
        }
        #expect(try await memory.calls.call("c6")?.progress.status == .started, "the end was not written either")
        await memory.store.close()
    }

    @Test("W1: a text typed where the target could not be attested ordinary is a declared gap of its own reason, beside a secure field's")
    func unclassifiedTargetGap() async throws {
        let memory = try await TaskFixtures.open()
        let typing = try AgentCallRecord(
            event: Self.event("c9"),
            request: .insertText(text: ValueMinimization.marker, expectedValue: ValueMinimization.marker)
        )
        let gaps = [
            ValueRedaction(eventID: "c9", location: .argument(name: "text", position: 0), reason: .unclassifiedTarget),
            ValueRedaction(eventID: "c9", location: .argument(name: "expected_value", position: 0), reason: .secureField),
        ]
        _ = try await memory.facts.open(try OperationOpening(call: typing, startedAtMS: TaskFixtures.t0 + 1, redactions: gaps))
        #expect(Set(try await memory.facts.redactions(of: "c9")) == Set(gaps))
        #expect(try await memory.count("SELECT count(*) FROM memory_value_redactions WHERE reason = 'unclassified_target'") == 1)
        await memory.store.close()
    }

    @Test("a value withheld at the opening is a declared gap; a value the conclusion withdraws is replaced by the marker, once")
    func withheldValues() async throws {
        let memory = try await TaskFixtures.open()
        let typing = try AgentCallRecord(
            event: Self.event("c7"),
            request: .typeText(target: "Password", text: ValueMinimization.marker, section: nil, replace: true)
        )
        let gap = ValueRedaction(eventID: "c7", location: .argument(name: "text", position: 0), reason: .secretTarget)
        _ = try await memory.facts.open(
            try OperationOpening(call: typing, startedAtMS: TaskFixtures.t0 + 1, redactions: [gap])
        )
        #expect(try await memory.facts.redactions(of: "c7") == [gap])

        let kept = try AgentCallRecord(
            event: Self.event("c8"),
            request: .insertText(text: "s3cr3t-value", expectedValue: nil)
        )
        _ = try await memory.facts.open(try OperationOpening(call: kept, startedAtMS: TaskFixtures.t0 + 2))
        let withdrawal = ValueRedaction(
            eventID: "c8",
            location: .argument(name: "text", position: 0),
            reason: .secureField
        )
        let end = try OperationConclusion(
            end: AgentCallTransition(
                "c8",
                AgentCallProgress(
                    .completed,
                    result: .outcome(.actedUnverified, message: "inserted"),
                    endedAtMS: TaskFixtures.t0 + 3
                )
            ),
            withdrawn: [withdrawal]
        )
        #expect(try await memory.facts.conclude(end) == .committed)
        #expect(try await memory.facts.conclude(end) == .alreadyApplied)
        let call = try #require(try await memory.calls.call("c8"))
        if case .insertText(let text, _) = call.request {
            #expect(text == ValueMinimization.marker)
        } else {
            Issue.record("not insert_text")
        }
        #expect(try await memory.count("""
            SELECT count(*) FROM memory_operation_arguments WHERE text_value = 's3cr3t-value'
            """) == 0)
        #expect(try await memory.facts.redactions(of: "c8") == [withdrawal])
        await memory.store.close()
    }

    @Test("a batch opens with its steps planned under the attempt as a container; each started step joins the attempt as an operation")
    func batchAttribution() async throws {
        let memory = try await TaskFixtures.open()
        try await TaskFixtures.begin(memory)
        let attribution = try TaskCallAttribution(taskID: "task-1", attemptID: "attempt-1", revision: 1)
        let (batch, steps) = try AgentCallFixtures.batch(
            "b1",
            [.act(target: "A", verb: .click, value: nil, section: nil),
             .act(target: "B", verb: .click, value: nil, section: nil)]
        )
        _ = try await memory.facts.open(
            batch: try BatchOpening(
                batch: batch,
                steps: steps,
                startedAtMS: AgentCallFixtures.t0,
                attribution: attribution
            )
        )
        _ = try await memory.facts.start(step: "b1.0", atMS: AgentCallFixtures.t0 + 1, attribution: attribution)
        let memberships = try await SQLiteTaskRepository(store: memory.store).memberships(of: "attempt-1")
        #expect(memberships.map(\.eventID) == ["b1", "b1.0"] && memberships.map(\.role) == [.context, .action])
        #expect(try await memory.facts.attribution(of: "b1.1") == nil,
                "a step that never started is not an operation of the attempt")
        await memory.store.close()
    }
}
