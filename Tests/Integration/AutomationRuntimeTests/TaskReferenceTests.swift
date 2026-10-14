//
//  TaskReferenceTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// TaskReferenceTests prove the structural reference `<task id>/<output>` on the path that knows its role (review F12): kept
/// when the producer's own task declared that output (in an earlier task, or in the statement written), with its version
/// checked; minimized as any text when it names nothing the archive vouches for (an unknown task, another producer's, an
/// output never declared, a version that is not the task's); never a way past the protection of secrets. Kept through an
/// update and a reopening, and read by the Recall as the dependency the source's attempt stated.
@MainActor
@Suite("Structural references to a task's output, through the tool and SQLite", .serialized, .automaticSelection)
struct TaskReferenceTests {
    typealias P = ProcedureLearningTests

    /// A task of `tools`'s producer that ended declaring the output `invoice_file`: its id and its attempt's.
    static func earlierTask(_ tools: AutomationTools) async throws -> (task: String, attempt: String) {
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Download the invoice","recall":false}"#)
        let task = try #require(begun["task"].string), attempt = try #require(begun["attempt"].string)
        _ = try await P.task(tools, #"{"operation":"end","outcome":"completed","outputs":[{"name":"invoice_file","kind":"file","value":"/tmp/inv.pdf","source":"observation"}]}"#)
        return (task, attempt)
    }

    static func references(_ session: LearningSession, task: String) throws -> [String] {
        try P.rows("""
            SELECT v.name || '=' || ifnull(v.source_ref, '-') || '@' || ifnull(v.source_version, '-') FROM memory_task_values v
            WHERE v.task_id = '\(task)' AND v.revision IS NOT NULL ORDER BY v.revision, v.position
            """, in: session)
    }

    @Test("an admitted reference and its version are kept as given, through an update of the task and a reopening of the archive")
    func keptThroughUpdateAndReopening() async throws {
        let session = P.photoSession(try W.directory())
        let tools = P.tools(session, stream: "references")
        let earlier = try await Self.earlierTask(tools)
        let reference = earlier.task + "/invoice_file"
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Email the invoice","recall":false,"inputs":[{"name":"attachment","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(reference)","source_version":"\#(earlier.attempt)"},{"name":"by_revision","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(reference)","source_version":"1"}]}"#)
        let task = try #require(begun["task"].string)
        let revised = try await P.task(tools, #"{"operation":"update","revision":1,"goal":"Email the invoice to Luca","inputs":[{"name":"recipient","value":"luca@example.com"}]}"#)
        #expect(revised["status"].string == "revised")
        let expected = ["attachment=\(reference)@\(earlier.attempt)", "by_revision=\(reference)@1"]
        #expect(try Self.references(session, task: task).filter { !$0.hasPrefix("recipient") } == expected + expected, "both revisions")
        await RecallLifecycleTests.close(session)
        // Reopened: the store reads the same rows, and the task's revision gives them back to the producer.
        let memory = MemoryService.shared(for: session.directory)
        let producer = try TaskProducer(source: .app, streamID: "references")
        let read = try await memory.perform { try await $0.tasks.revision(2, of: task, for: producer) }
        #expect(read?.content.inputs.first { $0.name == "attachment" }?.sourceRef == reference)
        #expect(read?.content.inputs.first { $0.name == "attachment" }?.sourceVersion == earlier.attempt)
        await RecallLifecycleTests.close(session)
    }

    /// The version beside a reference that is not admitted is minimized as any text too: an attempt's id has no credential's
    /// shape and stays, naming nothing the reference can use.
    @Test("a reference that names nothing the archive vouches for is minimized as any text; a plain output name is unchanged")
    func unresolvedReferencesInventNothing() async throws {
        let session = P.photoSession(try W.directory())
        let tools = P.tools(session, stream: "references")
        let other = P.tools(session, source: .mcp, stream: "another-client")
        let earlier = try await Self.earlierTask(tools)
        let foreign = try await Self.earlierTask(other)
        let unknown = UUID().uuidString
        let inputs: [(String, String, String?)] = [
            ("unknown_task", "\(unknown)/invoice_file", nil),
            ("undeclared_output", "\(earlier.task)/report_file", nil),
            ("foreign_task", "\(foreign.task)/invoice_file", nil),
            ("wrong_attempt", "\(earlier.task)/invoice_file", UUID().uuidString),
            ("later_revision", "\(earlier.task)/invoice_file", "7"),
            ("plain_name", "invoice_file", nil),
            ("lower_case", "\(earlier.task.lowercased())/invoice_file", nil),
        ]
        let list = inputs.map { name, reference, version in
            #"{"name":"\#(name)","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(reference)""#
                + (version.map { #","source_version":"\#($0)""# } ?? "") + "}"
        }.joined(separator: ",")
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Email the invoice","recall":false,"inputs":[\#(list)]}"#)
        let task = try #require(begun["task"].string)
        let stored = try Self.references(session, task: task)
        #expect(stored == [
            "unknown_task=[withheld]@-", "undeclared_output=[withheld]@-", "foreign_task=[withheld]@-",
            "wrong_attempt=[withheld]@\(inputs[3].2 ?? "")", "later_revision=[withheld]@7", "plain_name=invoice_file@-",
            "lower_case=\(earlier.task.lowercased())/invoice_file@-",
        ], "\(stored)")
        await RecallLifecycleTests.close(session)
    }

    @Test("secrets stay withheld: a credential in the output's name, and a declared secret, never reach SQLite")
    func secretsStayWithheld() async throws {
        let session = P.photoSession(try W.directory())
        let tools = P.tools(session, stream: "references")
        let earlier = try await Self.earlierTask(tools)
        let credential = "sk-ant-1234567890abcdefghijklmnopqrstuvwxyz"
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Email the invoice","recall":false,"inputs":[{"name":"pin","value":"731942","secret":true},{"name":"token_ref","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(earlier.task)/\#(credential)"},{"name":"pin_ref","kind":"file","value":"/tmp/inv.pdf","source":"previous_output","source_ref":"\#(earlier.task)/invoice_731942"}]}"#)
        let task = try #require(begun["task"].string)
        let everything = try P.rows("SELECT ifnull(source_ref, '') || ' ' || ifnull(text_value, '') FROM memory_task_values WHERE task_id = '\(task)'",
                                    in: session).joined(separator: " ")
        #expect(!everything.contains(credential) && !everything.contains("731942"), "\(everything)")
        await RecallLifecycleTests.close(session)
    }

    @Test("a checkpoint's output derived from another output it declares keeps its reference to the task being written")
    func sameTaskReferenceInCheckpoint() async throws {
        let session = P.photoSession(try W.directory())
        let tools = P.tools(session, stream: "references")
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Download and rename the invoice","recall":false}"#)
        let task = try #require(begun["task"].string)
        _ = try await P.task(tools, #"{"operation":"checkpoint","outputs":[{"name":"invoice_file","kind":"file","value":"/tmp/inv.pdf","source":"observation"},{"name":"renamed","kind":"file","value":"/tmp/renamed.pdf","source":"derived","source_ref":"\#(task)/invoice_file"},{"name":"stray","kind":"file","value":"/tmp/x.pdf","source":"derived","source_ref":"\#(task)/never_declared"}]}"#)
        let stored = try P.rows("SELECT name || '=' || ifnull(source_ref, '-') FROM memory_task_values WHERE task_id = '\(task)' ORDER BY position",
                                in: session)
        #expect(stored == ["invoice_file=-", "renamed=\(task)/invoice_file", "stray=[withheld]"], "\(stored)")
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
            let begun = try await P.task(tools, #"{"operation":"begin","goal":"Email invoice INV-2026-044 to Luca","inputs":[{"name":"invoice","value":"INV-2026-044"},{"name":"recipient","value":"luca@example.com"}],"needs":[{"text":"Email the invoice INV-2026-044 to luca@example.com"}]}"#)
            let need = try #require(begun["recall"]["needs"].array?.first)
            let conditions = need["selection"]["conditions"].array?.compactMap { $0["kind"].string } ?? []
            #expect(conditions.contains("input_produced") == produced, "\(need)")
            await RecallLifecycleTests.close(session)
        }
    }
}
