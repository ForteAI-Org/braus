//
//  ReviewCorrectionTests.swift
//  Mecum
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
@testable import SQLiteMemory
import Testing

/// The corrections of the D2 review through the product's own entry (`AutomationTools` over
/// `LearningSession`, the shared `MemoryService`, the real archive): a menu command and a dialog button
/// record their own perceptions before and after and keep their window check (F07); what was learned on
/// the window reaches the scene a model reads, and an unreadable memory is said there and gone once it
/// reads again (F02, F05); a call whose derived write was lost is recovered by the service on its own
/// (F03). These are integration proofs over a double of the operating system, not a live run.
@MainActor
@Suite("The review's corrections through the tools", .serialized)
struct ReviewCorrectionTests {

    typealias Learning = ProcedureLearningTests

    @Test("a menu command and a dialog button record the window before and after as their own call's samples, keep their window check, stay one step each, and teach where they lead")
    func nativeCommandsArePerceived() async throws {
        let session = Learning.photoSession(try W.directory())
        let tools = Learning.tools(session)
        _ = try await Learning.task(tools, #"{"operation":"begin","goal":"Open and close the export dialog"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        let menu = try await Learning.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export…"}"#)
        let after = menu["observation"]["scene"].string ?? menu["observation"]["changes"].string ?? ""
        #expect(after.contains("memory:"), "the scene after the command says what the memory knows: \(menu)")
        _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        let ended = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        #expect(ended["candidate"]["steps"].array?.map { $0["tool"].string ?? "" } == ["menu", "press"], "one step per command")
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let samples = try Learning.rows("""
            SELECT a.tool_kind || ':' || o.phase FROM memory_event_observations o JOIN memory_agent_actions a ON a.event_id = o.event_id
            WHERE a.tool_kind IN ('menu', 'press') AND o.observation_kind = 'capture' ORDER BY a.tool_kind, o.phase
            """, in: session)
        #expect(samples == ["menu:after", "menu:before", "press:after", "press:before"], "\(samples)")
        #expect(try Learning.rows("""
            SELECT DISTINCT v.condition_kind FROM memory_operation_verifications v
            JOIN memory_agent_actions a ON a.event_id = v.call_event_id WHERE a.tool_kind IN ('menu', 'press')
            """, in: session) == ["window_set_changed"], "the window check is the one the command reports")
        let relations = try await memory.perform { try await $0.relations.relations(of: Learning.preview) }
        let commands = relations.filter { $0.key.verb == .menu || $0.key.verb == .press }
        #expect(commands.count == 2 && commands.allSatisfy { $0.key.toSceneID != nil && $0.key.toSceneID != $0.key.fromSceneID },
                "the menu leads from the editing window to the dialog and the button back: \(commands.map(\.summary))")
        #expect(commands.contains { $0.key.argumentsKey == "path=file>export" && $0.standing == .candidate })
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a command refused before any gesture records no sample and teaches nothing")
    func refusedCommandRecordsNothing() async throws {
        let session = Learning.photoSession(try W.directory())
        session.windows[Learning.preview] = Learning.Preview.export
        session.script["press|Save"] = LearningSession.Outcome(kind: .refused, gesture: false)
        let tools = Learning.tools(session)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        _ = try await Learning.call(tools, "press", #"{"session":"\#(id)","button":"Save"}"#)
        #expect(!session.gestures.contains("press|Save"))
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        #expect(try Learning.rows("""
            SELECT count(*) FROM memory_event_observations o JOIN memory_agent_actions a ON a.event_id = o.event_id
            WHERE a.tool_kind = 'press'
            """, in: session) == ["0"])
        #expect(try Learning.rows("SELECT count(*) FROM brain_relations", in: session) == ["0"])
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a choice or a menu command whose fixed argument was withheld teaches no relation, since a placeholder would be in the key; a typed secret teaches none either, its check holding it")
    func withheldFixedArgument() async throws {
        let session = Learning.photoSession(try W.directory())
        session.windows[Learning.preview] = Learning.Preview.export
        let tools = Learning.tools(session)
        let secret = "codec-9Z1-canary"
        _ = try await Learning.task(tools, #"""
            {"operation":"begin","goal":"Export in the house format","inputs":[{"name":"format","value":"\#(secret)","secret":true}]}
            """#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        for _ in 0..<2 {
            _ = try await Learning.call(tools, "select", #"{"session":"\#(id)","control":"Format","item":"\#(secret)"}"#)
            _ = try await Learning.call(tools, "type_text", #"{"session":"\#(id)","target":"foto_demo.png","text":"\#(secret)"}"#)
            // A command whose check is the window's, which holds nothing of the path: only the path is withheld.
            _ = try await Learning.call(tools, "menu", #"{"session":"\#(id)","path":"File > Export as \#(secret)"}"#)
        }
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let reasons = try Learning.rows("""
            SELECT a.tool_kind || ':' || v.outcome || ':' || ifnull(v.reason, '-') FROM brain_relation_evaluations v
            JOIN memory_agent_actions a ON a.event_id = v.call_event_id
            WHERE v.sequence = (SELECT max(w.sequence) FROM brain_relation_evaluations w WHERE w.call_event_id = v.call_event_id)
            ORDER BY a.tool_kind, v.call_event_id
            """, in: session)
        #expect(reasons.filter { $0.hasPrefix("select:") } == ["select:excluded:value_withheld", "select:excluded:value_withheld"], "\(reasons)")
        #expect(reasons.filter { $0.hasPrefix("menu:") } == ["menu:excluded:value_withheld", "menu:excluded:value_withheld"], "\(reasons)")
        let keys = try Learning.rows("SELECT verb || ' ' || arguments_key FROM brain_relations", in: session)
        #expect(!keys.contains { $0.hasPrefix("select") || $0.hasPrefix("menu") }, "no relation keyed by a placeholder: \(keys)")
        #expect(reasons.filter { $0.hasPrefix("type_text:") } == ["type_text:excluded:value_withheld", "type_text:excluded:value_withheld"],
                "a typed secret is a parameter, but the value its check read back is withheld: \(reasons)")
        #expect(try archiveOccurrences(of: secret, in: memory.url).isEmpty)
        await memory.close()
        MemoryService.forget(session.directory)
    }

    @Test("a shortcut learned on the window reaches the scene the model reads; an unreadable memory is said there with the live scene, and gone once the memory reads again")
    func windowKnowledgeAndDegradation() async throws {
        let session = Learning.photoSession(try W.directory())
        session.script["press_key|s"] = LearningSession.Outcome(effect: .windowTitleChanged(title: "Saved"))
        let tools = Learning.tools(session)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Learning.preview)"}"#)
        for _ in 0..<2 {
            _ = try await Learning.call(tools, "press_key", #"{"session":"\#(id)","key":"s","modifiers":["cmd"]}"#)
        }
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let observed = try await Learning.call(tools, "observe", #"{"session":"\#(id)"}"#)
        let scene = observed["scene"].string ?? observed["changes"].string ?? ""
        #expect(scene.contains("  window: press_key [key=s;modifiers=cmd;count=1]: windowTitleChanged")
                && scene.contains("acts on the focused element, which was not recorded"), "\(scene)")
        await memory.close()
        let unreadable = try await Learning.call(tools, "observe", #"{"session":"\#(id)","full":true}"#)
        let degraded = unreadable["scene"].string ?? unreadable["changes"].string ?? ""
        #expect(degraded.contains("memory: unavailable right now") && degraded.contains("Rotate Right"), "\(degraded)")
        #expect(unreadable["memory"].string?.contains("not recorded") == true, "the call itself says it was not recorded")
        #expect(!degraded.contains("SQLITE") && !degraded.contains("closed"), "the error stays in the process: \(degraded)")
        MemoryService.forget(session.directory)
        let again = try await Learning.call(tools, "observe", #"{"session":"\#(id)","full":true}"#)
        let healthy = again["scene"].string ?? again["changes"].string ?? ""
        #expect(healthy.contains("  window: press_key") && !healthy.contains("unavailable"), "\(healthy)")
        await MemoryService.shared(for: session.directory).close()
        MemoryService.forget(session.directory)
    }

    @Test("calls whose derived writes were lost (a queue that dropped them) are evaluated by the next open's recovery, once, their samples placed on the way")
    func lostDerivedWritesRecovered() async throws {
        let directory = try W.directory()
        // A queue that admits nothing loses every derived write, as a stopped process does: the calls' facts are
        // confirmed, as essential writes are, and no scene association and no relation is ever written.
        var dropping = MemoryService.Configuration()
        dropping.queueLimit = 0
        let lossy = MemoryService(directory: directory, configuration: dropping)
        _ = try await lossy.ready()
        #expect(await lossy.flush(within: .seconds(10)), "the open's own recovery pass is over before any call")
        let editing = BrainRelationLearningTests.window([BrainRelationLearningTests.export, BrainRelationLearningTests.cancel])
        let dialog = BrainRelationLearningTests.window([BrainRelationLearningTests.save, BrainRelationLearningTests.cancel],
                                                        title: "Export", surface: .dialog)
        var calls: [String] = []
        for _ in 0..<2 {
            calls.append(try await BrainRelationLearningTests.act(lossy, BrainRelationLearningTests.export, before: editing, after: dialog,
                                                                  check: BrainRelationLearningTests.passed(BrainRelationLearningTests.export)))
        }
        #expect(await lossy.status().dropped > 0)
        let firstCall = calls[0]
        #expect(try await lossy.perform { try await $0.relations.application(of: firstCall) } == nil)
        await lossy.close()

        let reopened = MemoryService(directory: directory)
        _ = try await reopened.ready()
        #expect(await reopened.flush(within: .seconds(10)))
        let status = await reopened.status()
        #expect(status.relationRecovery.recovered == 2 && status.relationRecovery.associated >= 2 && !status.relationRecoveryPending,
                "\(status.relationRecovery)")
        for call in calls {
            let history = try await reopened.perform { try await $0.relations.evaluations(of: call) }
            #expect(history.map(\.cause) == [.recovery, .evidence] && history.last?.outcome == .supported,
                    "recovered waiting for its state, then evaluated once it was placed: \(history)")
        }
        let relations = try await reopened.perform { try await $0.relations.relations(of: BrainRelationLearningTests.bundle) }
        #expect(relations.count == 1 && relations.first?.supports == 2 && relations.first?.standing == .exposed)
        #expect(try await reopened.perform { try await $0.relations.applyPending(at: 9_000) } == 0)
        await reopened.close()
    }
}
