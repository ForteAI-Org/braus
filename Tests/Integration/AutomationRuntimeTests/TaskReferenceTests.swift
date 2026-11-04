@testable import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// Exercises structural-reference admission at the decoder and task-store boundary.
@MainActor
@Suite("Structural references at the task producer boundary", .serialized)
struct TaskReferenceTests {
    typealias P = ProcedureLearningTests

    private static func content(_ arguments: String) throws -> TaskRevisionContent {
        guard case .begin(let content, _, _) = try MemoryTaskTool.decode(P.json(arguments),
            minimization: ValueMinimization(), messageRef: nil) else {
            throw AutomationFailure("Expected task content in this fixture")
        }
        return content
    }

    private static func checkpoint(_ arguments: String) throws -> TaskCheckpointDraft {
        let request = try MemoryTaskTool.decode(P.json(arguments), minimization: ValueMinimization(), messageRef: nil)
        switch request {
        case .checkpoint(let draft, _, _, _), .end(let draft, _, _, _): return draft
        default: throw AutomationFailure("Expected a checkpoint in this fixture")
        }
    }

    static func earlierTask(memory: MemoryService, producer: TaskProducer) async throws -> OpenTask {
        let open = try await TaskChannel.begin(content(#"{"operation":"begin","goal":"Download the invoice","recall":false}"#),
            producer: producer, traceID: nil, memory: memory)
        _ = try await TaskChannel.checkpoint(open,
            checkpoint(#"{"operation":"end","outcome":"completed","outputs":[{"name":"invoice_file","kind":"file","value":"/tmp/inv.pdf","source":"observation"}]}"#),
            producer: producer, memory: memory)
        return open
    }

    static func references(_ session: LearningSession, task: String) throws -> [String] {
        try P.rows("""
            SELECT v.name || '=' || ifnull(v.source_ref, '-') || '@' || ifnull(v.source_version, '-') FROM memory_task_values v
            WHERE v.task_id = (SELECT task_id FROM memory_tasks WHERE task_uuid = '\(task)')
              AND v.revision IS NOT NULL ORDER BY v.revision, v.position
            """, in: session)
    }

    @Test("an admitted reference and its version survive revision and archive reopening")
    func keptThroughUpdateAndReopening() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        let producer = try TaskProducer(source: .app, streamID: "references")
        let earlier = try await Self.earlierTask(memory: memory, producer: producer)
        let reference = earlier.taskID + "/invoice_file"
        let raw = #"{"operation":"begin","goal":"Email the invoice","recall":false,"inputs":[{"name":"attachment","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(reference)","source_version":"\#(earlier.attemptID)"},{"name":"by_revision","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(reference)","source_version":"1"}]}"#
        let begun = try await TaskChannel.begin(Self.content(raw), producer: producer, traceID: nil, memory: memory)
        let previous = try await TaskChannel.revision(1, of: begun.taskID, producer: producer, memory: memory)
        guard case .update(let update, _) = try MemoryTaskTool.decode(
            P.json(#"{"operation":"update","revision":1,"goal":"Email the invoice to Luca","inputs":[{"name":"recipient","value":"luca@example.com"}]}"#),
            minimization: ValueMinimization(), messageRef: nil) else {
            Issue.record("Expected a revision fixture")
            await RecallLifecycleTests.close(session)
            return
        }
        let revised = try await TaskChannel.revise(begun, expecting: 1,
            content: update.applied(to: previous.content, messageRef: nil), reason: nil, producer: producer, memory: memory)
        #expect(revised.revision == 2)
        let expected = ["attachment=\(reference)@\(earlier.attemptID)", "by_revision=\(reference)@1"]
        #expect(try Self.references(session, task: begun.taskID).filter { !$0.hasPrefix("recipient") } == expected + expected)
        await RecallLifecycleTests.close(session)
        let reopened = MemoryService.shared(for: session.directory)
        let read = try await reopened.perform { try await $0.tasks.revision(2, of: begun.taskID, for: producer) }
        #expect(read?.content.inputs.first { $0.name == "attachment" }?.sourceRef == reference)
        #expect(read?.content.inputs.first { $0.name == "attachment" }?.sourceVersion == earlier.attemptID)
        await RecallLifecycleTests.close(session)
    }

    @Test("unresolved references name no data and plain output names are unchanged")
    func unresolvedReferencesInventNothing() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        let producer = try TaskProducer(source: .app, streamID: "references")
        let other = try TaskProducer(source: .mcp, streamID: "another-client")
        let earlier = try await Self.earlierTask(memory: memory, producer: producer)
        let foreign = try await Self.earlierTask(memory: memory, producer: other)
        let inputs: [(String, String, String?)] = [
            ("unknown_task", "\(UUID().uuidString)/invoice_file", nil),
            ("undeclared_output", "\(earlier.taskID)/report_file", nil),
            ("foreign_task", "\(foreign.taskID)/invoice_file", nil),
            ("wrong_attempt", "\(earlier.taskID)/invoice_file", UUID().uuidString),
            ("later_revision", "\(earlier.taskID)/invoice_file", "7"),
            ("plain_name", "invoice_file", nil),
            ("lower_case", "\(earlier.taskID.lowercased())/invoice_file", nil)
        ]
        let list = inputs.map { name, reference, version in
            #"{"name":"\#(name)","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(reference)""#
                + (version.map { #","source_version":"\#($0)""# } ?? "") + "}"
        }.joined(separator: ",")
        let begun = try await TaskChannel.begin(Self.content(#"{"operation":"begin","goal":"Email the invoice","recall":false,"inputs":[\#(list)]}"#),
            producer: producer, traceID: nil, memory: memory)
        let stored = try Self.references(session, task: begun.taskID)
        #expect(stored == [
            "unknown_task=[withheld]@-", "undeclared_output=[withheld]@-", "foreign_task=[withheld]@-",
            "wrong_attempt=[withheld]@\(inputs[3].2 ?? "")", "later_revision=[withheld]@7", "plain_name=invoice_file@-",
            "lower_case=\(earlier.taskID.lowercased())/invoice_file@-"
        ])
        await RecallLifecycleTests.close(session)
    }

    @Test("declared secrets and credential-shaped references never reach SQLite")
    func secretsStayWithheld() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        let producer = try TaskProducer(source: .app, streamID: "references")
        let earlier = try await Self.earlierTask(memory: memory, producer: producer)
        let credential = "sk-test-REFERENCE-FIXTURE01234567890123456789"
        let raw = #"{"operation":"begin","goal":"Email the invoice","recall":false,"inputs":[{"name":"pin","value":"731942","secret":true},{"name":"token_ref","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(earlier.taskID)/\#(credential)"},{"name":"pin_ref","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(earlier.taskID)/invoice_731942"}]}"#
        let begun = try await TaskChannel.begin(Self.content(raw), producer: producer, traceID: nil, memory: memory)
        let taskID = begun.taskID
        let everything = try P.rows("""
            SELECT ifnull(source_ref, '') || ' ' || ifnull(text_value, '') FROM memory_task_values
            WHERE task_id = (SELECT task_id FROM memory_tasks WHERE task_uuid = '\(taskID)')
            """, in: session).joined(separator: " ")
        #expect(!everything.contains(credential) && !everything.contains("731942"))
        await RecallLifecycleTests.close(session)
    }

    @Test("outputs derived from this task retain only references to outputs the checkpoint declares")
    func sameTaskReferenceInCheckpoint() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        let producer = try TaskProducer(source: .app, streamID: "references")
        let begun = try await TaskChannel.begin(Self.content(#"{"operation":"begin","goal":"Download and rename the invoice","recall":false}"#),
            producer: producer, traceID: nil, memory: memory)
        let taskID = begun.taskID
        _ = try await TaskChannel.checkpoint(begun,
            Self.checkpoint(#"{"operation":"checkpoint","outputs":[{"name":"invoice_file","kind":"file","value":"/tmp/inv.pdf","source":"observation"},{"name":"renamed","kind":"file","value":"/tmp/renamed.pdf","source":"derived","source_ref":"\#(taskID)/invoice_file"},{"name":"stray","kind":"file","value":"/tmp/x.pdf","source":"derived","source_ref":"\#(taskID)/never_declared"}]}"#),
            producer: producer, memory: memory)
        let stored = try P.rows("""
            SELECT name || '=' || ifnull(source_ref, '-') FROM memory_task_values
            WHERE task_id = (SELECT task_id FROM memory_tasks WHERE task_uuid = '\(taskID)') ORDER BY position
            """, in: session)
        #expect(stored == ["invoice_file=-", "renamed=\(taskID)/invoice_file", "stray=[withheld]"])
        await RecallLifecycleTests.close(session)
    }

    @Test("an interpretation's input taken from an output of the same task, by its id: the Recall reads the dependency; an output never declared, none")
    func dependencyRecalledThroughTheReference() async throws {
        for (reference, produced) in [("{task}/invoice_file", true), ("{task}/never_declared", false)] {
            let corpus = try RecallScopeTests.invoiceCorpus(attachmentSource: #""source":"previous_output","source_ref":"\#(reference)""#)
            let (session, _) = try await RecallScopeTests.learned(corpus)
            let bindings = try P.rows("""
                SELECT ifnull(b.source_ref, '-') FROM memory_parameter_bindings b JOIN memory_route_parameters r
                  ON r.route_id = b.route_id AND r.parameter_id = b.parameter_id WHERE r.name = 'attachment' AND b.source = 'previous_output'
                """, in: session)
            #expect(!bindings.isEmpty && bindings.allSatisfy { produced ? TaskOutputReference($0)?.output == "invoice_file" : $0 == "[withheld]" },
                    "\(bindings)")
            let tools = P.tools(session, stream: "dependent")
            let begun = try await HistoricalRecallFixture.beginQuery(tools, #"{"operation":"begin","goal":"Email invoice INV-2026-044 to Luca","inputs":[{"name":"invoice","value":"INV-2026-044"},{"name":"recipient","value":"luca@example.com"}],"needs":[{"text":"Email the invoice INV-2026-044 to luca@example.com"}]}"#)
            let need = try #require(begun["recall"]["needs"].array?.first)
            let conditions = need["selection"]["conditions"].array?.compactMap { $0["kind"].string } ?? []
            #expect(conditions.contains("input_produced") == produced, "\(need)")
            await RecallLifecycleTests.close(session)
        }
    }
}
