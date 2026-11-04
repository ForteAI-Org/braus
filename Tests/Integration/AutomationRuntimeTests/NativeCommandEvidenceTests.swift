//
//  NativeCommandEvidenceTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// What a dialog button's call keeps when its gesture was made and what follows it goes wrong (review
/// F07b), through the product's own entry (`AutomationTools` over `LearningSession`, whose press runs
/// `PerceivedCommand` and, after its one gesture, the production `MenuBarCommand.observedOutcome`), with the
/// real recorder and a temporary SQLite archive: the window before it, once; no window after it made up;
/// an unknown check that says no scene was read after it; nothing taught or admitted on it. A cancellation
/// after the gesture keeps the window before it and ends the call cancelled; one before any gesture, like a
/// refusal, records nothing. These run over a double of the operating system, not a live desktop.
@MainActor
@Suite("A native command keeps what it perceived when what follows its gesture goes wrong", .serialized)
struct NativeCommandEvidenceTests {

    typealias Learning = ProcedureLearningTests

    static func pressSession(_ outcome: LearningSession.Outcome) throws -> LearningSession {
        let session = Learning.photoSession(try W.directory())
        session.windows[Learning.preview] = Learning.Preview.export
        session.script["press|Save"] = outcome
        return session
    }

    /// The press call's samples, its check with its limits, and how the call ended.
    static func evidence(_ session: LearningSession) throws -> (samples: [String], check: [String], limits: [String], status: [String]) {
        let press = "SELECT event_id FROM memory_agent_actions WHERE tool_kind = 'press'"
        return (
            try Learning.rows("""
                SELECT phase FROM memory_event_observations WHERE event_id IN (\(press)) AND observation_kind = 'capture' ORDER BY phase
                """, in: session),
            try Learning.rows("""
                SELECT v.condition_kind || ':' || m.verdict || ':' || v.performed FROM memory_operation_verifications v
                JOIN memory_verifications m ON m.event_id = v.event_id WHERE v.call_event_id IN (\(press))
                """, in: session),
            try Learning.rows("""
                SELECT l.limit_kind FROM memory_operation_verification_limits l JOIN memory_operation_verifications v
                ON v.event_id = l.event_id WHERE v.call_event_id IN (\(press)) ORDER BY l.limit_kind
                """, in: session),
            try Learning.rows("SELECT execution_status FROM memory_agent_actions WHERE tool_kind = 'press'", in: session)
        )
    }

    @Test("a press whose window after it cannot be perceived keeps the window before it once, makes up no window after it, says its effect is unknown with no scene after it, and teaches or admits nothing")
    func afterPerceptionFails() async throws {
        let session = try Self.pressSession(LearningSession.Outcome(afterPerception: .fails))
        let tools = Learning.tools(session)
        _ = try await Learning.task(tools, #"{"request":"Close the export dialog"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        let pressed = "\(try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#))"
        #expect(pressed.contains("unknown") && pressed.contains("not_readable"), "\(pressed)")
        #expect(!pressed.contains("secret-canary") && !pressed.contains("4242"), "the perception's error stays in the process")
        #expect(session.gestures == ["press|Save"], "one gesture, never repeated to repair the trace")
        let ended = try await Learning.task(tools, #"{"outcome":"completed"}"#)
        let candidate = try await Learning.candidateIDFixture(tools, session)
        #expect((try await Learning.candidateFixture(tools, session))["steps"].array?.count == 1, "the press is one step")
        let answer = try await Learning.interpretFixture(tools, session, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Close the export dialog"},
             "steps":[{"step":1,"label":"Confirm the export"}]}
            """#)
        #expect(Learning.verdicts(answer).allSatisfy { !$0.hasSuffix(":admitted") }, "nothing admitted on an unknown check: \(answer)")
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let evidence = try Self.evidence(session)
        #expect(evidence.samples == ["before"], "the window before it, once; none after it: \(evidence.samples)")
        #expect(evidence.check == ["window_set_changed:unknown:requested"], "\(evidence.check)")
        #expect(evidence.limits == ["command_effect_unchecked", "no_after_scene"], "\(evidence.limits)")
        #expect(evidence.status == ["completed"])
        #expect(try Learning.rows("""
            SELECT v.outcome || ':' || ifnull(v.reason, '-') FROM brain_relation_evaluations v
            JOIN memory_agent_actions a ON a.event_id = v.call_event_id WHERE a.tool_kind = 'press'
            """, in: session) == ["excluded:verdict_unknown"])
        #expect(try Learning.rows("SELECT count(*) FROM brain_relations", in: session) == ["0"])
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a cancelled observation after dispatch retains an unknown sent command; cancellation before dispatch records no gesture")
    func cancellation() async throws {
        for (outcome, gestures, samples) in [(LearningSession.Outcome(afterPerception: .cancelled), ["press|Save"], ["before"]),
                                             (LearningSession.Outcome(cancelledBeforeGesture: true), [], [])] {
            let session = try Self.pressSession(outcome)
            let tools = Learning.tools(session)
            _ = try await Learning.task(tools, #"{"request":"Close the export dialog"}"#)
            let id = session.id!.uuidString
            _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
            if outcome.cancelledBeforeGesture {
                await #expect(throws: CancellationError.self) {
                    _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
                }
            } else {
                _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
            }
            #expect(session.gestures == gestures)
            let memory = MemoryService.shared(for: session.directory)
            #expect(await memory.flush(within: .seconds(10)))
            let evidence = try Self.evidence(session)
            #expect(evidence.samples == samples)
            #expect(evidence.status == [outcome.cancelledBeforeGesture ? "cancelled" : "completed"])
            #expect(evidence.check == (outcome.cancelledBeforeGesture ? [] : ["window_set_changed:unknown:requested"]))
            #expect(try Learning.rows("SELECT count(*) FROM brain_relations", in: session) == ["0"])
            await memory.close()
            MemoryService.forget(session.directory)
        }
    }

    @Test("a call cancelled while the window before its command is perceived, by the perception or by its task, reaches the tools as a cancellation: no gesture, no sample, no check, the call cancelled, nothing taught or admitted",
          arguments: [LearningSession.Outcome.BeforePerception.cancelled, .taskCancelled])
    func cancelledBeforeTheCommand(_ before: LearningSession.Outcome.BeforePerception) async throws {
        let session = try Self.pressSession(LearningSession.Outcome(beforePerception: before))
        let tools = Learning.tools(session)
        _ = try await Learning.task(tools, #"{"request":"Close the export dialog"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        // The press runs in a task of its own, the one its perception cancels, as a turn's stop would.
        let pressed = await Task { @MainActor in
            try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        }.result
        #expect(throws: CancellationError.self) { try pressed.get() }
        #expect(session.gestures.isEmpty, "\(before): the command never started")
        let ended = try await Learning.task(tools, #"{"outcome":"completed"}"#)
        if let candidate = try? await Learning.candidateIDFixture(tools, session) {
            let answer = try await Learning.interpretFixture(tools, session, #"""
                {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Close the export dialog"},
                 "steps":[{"step":1,"label":"Confirm the export"}]}
                """#)
            #expect(Learning.verdicts(answer).allSatisfy { !$0.hasSuffix(":admitted") }, "\(answer)")
        }
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let evidence = try Self.evidence(session)
        #expect(evidence.samples.isEmpty && evidence.check.isEmpty && evidence.status == ["cancelled"], "\(before): \(evidence)")
        #expect(try Learning.rows("SELECT count(*) FROM brain_relations", in: session) == ["0"])
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a perception before the command that fails for another reason keeps the policy it had: no window before it, the command made once, its window after it and its check kept")
    func ordinaryFailureBeforeTheCommand() async throws {
        let session = try Self.pressSession(LearningSession.Outcome(beforePerception: .fails))
        let tools = Learning.tools(session)
        _ = try await Learning.task(tools, #"{"request":"Close the export dialog"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        #expect(session.gestures == ["press|Save"])
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let evidence = try Self.evidence(session)
        #expect(evidence.samples == ["after"] && evidence.check == ["window_set_changed:passed:requested"] && evidence.status == ["completed"],
                "\(evidence)")
        #expect(try Learning.rows("""
            SELECT v.outcome || ':' || ifnull(v.reason, '-') FROM brain_relation_evaluations v
            JOIN memory_agent_actions a ON a.event_id = v.call_event_id WHERE a.tool_kind = 'press'
            """, in: session) == ["excluded:no_before_state"], "no state before it, no relation")
        await memory.close()
        MemoryService.forget(session.directory)
    }

    private nonisolated struct SettledCommand: Settling {
        func settle(in processID: pid_t, cap: Duration) async -> SettleResult { .settled }
    }

    @Test("a dispatched press retains its scene and check, or an unknown effect when its observation fails or is cancelled")
    func productionPressConclusion() async throws {
        struct Unreadable: Error {}
        let scene = SceneSnapshot(bundleID: "com.example.App", appName: "App", windowTitle: "Export",
                                  viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: [])
        func conclude(changed: Bool, observe: @escaping @MainActor () async throws -> SceneSnapshot) async throws -> ActOutcome {
            try await MenuBarCommand.observedOutcome("Save", outcome: ActOutcome(.foundActed, "Pressed"),
                processID: 42, before: ["before"], settling: SettledCommand(),
                signature: { _ in changed ? ["after"] : ["before"] }, observe: observe)
        }
        let changed = try await conclude(changed: true, observe: { scene })
        #expect(changed.kind == .foundActed && changed.scene == scene && changed.check?.verdict == .passed)
        let unchanged = try await conclude(changed: false, observe: { scene })
        #expect(unchanged.kind == .actedUnverified && unchanged.check?.verdict == .unknown)
        let unread = try await conclude(changed: true, observe: { throw Unreadable() })
        #expect(unread.kind == .actedUnverified && unread.scene == nil)
        #expect(unread.check?.verdict == .unknown && unread.check?.limits.contains(.noAfterScene) == true)
        let cancelled = try await conclude(changed: true, observe: { throw CancellationError() })
        #expect(cancelled.outcome.gesture == .sent)
        #expect(cancelled.scene == nil && cancelled.check?.verdict == .unknown)
        #expect(cancelled.check?.limits.contains(.noAfterScene) == true)
    }
}
