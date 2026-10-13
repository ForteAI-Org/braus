//
//  NativeCommandEvidenceTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SQLiteMemory
import Testing

/// What a dialog button's call keeps when its gesture was made and what follows it goes wrong (review
/// F07b), through the product's own entry (`AutomationTools` over `LearningSession`, whose press runs
/// `PerceivedCommand` and, after its one gesture, the production `DialogButtonPress.observed`), with the
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
        _ = try await Learning.task(tools, #"{"operation":"begin","goal":"Close the export dialog"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        let pressed = "\(try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#))"
        #expect(pressed.contains("could not be perceived after it") && pressed.contains("Do not press it again"), "\(pressed)")
        #expect(!pressed.contains("secret-canary") && !pressed.contains("4242"), "the perception's error stays in the process")
        #expect(session.gestures == ["press|Save"], "one gesture, never repeated to repair the trace")
        let ended = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        #expect(ended["candidate"]["steps"].array?.count == 1, "the press is one step")
        let answer = try await Learning.task(tools, #"""
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

    @Test("a call cancelled while the window after its gesture is perceived keeps the window before it once and ends cancelled; one cancelled before any gesture records nothing, as a refusal")
    func cancellation() async throws {
        for (outcome, gestures, samples) in [(LearningSession.Outcome(afterPerception: .cancelled), ["press|Save"], ["before"]),
                                             (LearningSession.Outcome(cancelledBeforeGesture: true), [], [])] {
            let session = try Self.pressSession(outcome)
            let tools = Learning.tools(session)
            let id = session.id!.uuidString
            _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
            await #expect(throws: CancellationError.self) {
                _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
            }
            #expect(session.gestures == gestures)
            let memory = MemoryService.shared(for: session.directory)
            #expect(await memory.flush(within: .seconds(10)))
            let evidence = try Self.evidence(session)
            #expect(evidence.samples == samples && evidence.check.isEmpty && evidence.status == ["cancelled"], "\(evidence)")
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
        _ = try await Learning.task(tools, #"{"operation":"begin","goal":"Close the export dialog"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        // The press runs in a task of its own, the one its perception cancels, as a turn's stop would.
        let pressed = await Task { @MainActor in
            try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        }.result
        #expect(throws: CancellationError.self) { try pressed.get() }
        #expect(session.gestures.isEmpty, "\(before): the command never started")
        let ended = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        if let candidate = ended["candidate"]["id"].string {
            let answer = try await Learning.task(tools, #"""
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

    @Test("the production press concludes a dispatched gesture by what follows it: a scene and the window check, an unknown check with no scene after it, or the cancellation thrown")
    func productionPressConclusion() async throws {
        struct Unreadable: Error {}
        let scene = SceneSnapshot(bundleID: "com.example.App", appName: "App", windowTitle: "Export",
                                  viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: [])
        let changed = try await DialogButtonPress.observed("Save", observe: { scene }, windowsChanged: { true })
        #expect(changed.kind == .foundActed && changed.scene == scene && changed.check?.verdict == .passed)
        let unchanged = try await DialogButtonPress.observed("Save", observe: { scene }, windowsChanged: { false })
        #expect(unchanged.kind == .actedUnverified && unchanged.check?.verdict == .unknown)
        var asked = false
        let unread = try await DialogButtonPress.observed("Save", observe: { throw Unreadable() }, windowsChanged: { asked = true; return true })
        #expect(unread.kind == .actedUnverified && unread.scene == nil && !asked)
        #expect(unread.check?.verdict == .unknown && unread.check?.limits.contains(.noAfterScene) == true)
        await #expect(throws: CancellationError.self) {
            _ = try await DialogButtonPress.observed("Save", observe: { throw CancellationError() }, windowsChanged: { true })
        }
    }
}
