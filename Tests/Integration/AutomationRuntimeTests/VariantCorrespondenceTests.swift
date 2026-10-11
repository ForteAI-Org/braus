//
//  VariantCorrespondenceTests.swift
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

/// Brings an archive back to exactly schema 4, as the first correction of D2 wrote it: what schema 5 adds
/// is dropped, and nothing of schema 4 is touched.
func downgradeToSchema4(_ url: URL) throws {
    let raw = try SQLiteConnection(path: url.path)
    defer { raw.close() }
    for object in try SQLiteMemorySchema.objectsAdded(since: 4) { try raw.execute("DROP \(object.type.uppercased()) \(object.name)") }
    try raw.execute("DELETE FROM memory_schema_migrations WHERE to_version > 4")
    try raw.execute("INSERT OR IGNORE INTO memory_schema_migrations (to_version, from_version, migrated_at_ms) VALUES (4, 0, 0)")
    try raw.execute("PRAGMA user_version = 4")
}

/// A variant's prefix through the product's own entry (`memory_task interpret` over `LearningSession`,
/// the real archive), its parameters matched one to one with its origin's (review F04b): a file typed in
/// two fields as one parameter is not the same method as two independent parameters, which stays
/// suggested and says why, in the version read back and in the diagnosis; the same parameter renamed, with
/// new values, is verified. A prefix the first correction's build stated verified is checked again when
/// its archive migrates, its first record kept.
@MainActor
@Suite("A variant's prefix keeps its parameters' correspondence, through the tools", .serialized)
struct VariantCorrespondenceTests {

    typealias Learning = ProcedureLearningTests

    static let app = "com.example.Saver"

    static func field(_ name: String, y: Double) -> SceneElement {
        SceneElement(id: "field|\(name.lowercased())", kind: .control, label: name,
                     bounds: NormalizedRect(x: 0.3, y: y, width: 0.3, height: 0.04), role: "AXTextField", labelOrigin: .description)
    }

    static func session() throws -> LearningSession {
        let session = LearningSession(directory: try W.directory())
        session.windows[app] = LearningSession.Window(elements: [
            field("Name", y: 0.2), field("Destination", y: 0.3),
            LearningSession.button("Save", x: 0.8), LearningSession.button("Cancel", x: 0.7),
        ], surface: .dialog, title: "Save As")
        return session
    }

    /// One attempt: the same text typed in both fields, then a button.
    static func attempt(_ tools: AutomationTools, _ session: LearningSession, goal: String, text: String,
                        button: String) async throws -> String {
        _ = try await Learning.task(tools, #"{"operation":"begin","goal":"\#(goal)"}"#)
        let id = session.id!.uuidString
        _ = try await Learning.call(tools, "open_session", #"{"app":"\#(app)"}"#)
        _ = try await Learning.call(tools, "type_text", #"{"session":"\#(id)","target":"Name","text":"\#(text)"}"#)
        _ = try await Learning.call(tools, "type_text", #"{"session":"\#(id)","target":"Destination","text":"\#(text)"}"#)
        _ = try await Learning.call(tools, "act", #"{"session":"\#(id)","target":"\#(button)"}"#)
        let ended = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        return try #require(ended["candidate"]["id"].string)
    }

    /// An interpretation whose two typed texts use the named parameters, with this attempt's value.
    static func interpretation(_ candidate: String, _ first: String, _ second: String, value: String,
                               variantOf origin: String? = nil) -> String {
        let names = Array(Set([first, second])).sorted()
        let parameters = names.map { #"{"name":"\#($0)","role":"a file name","kind":"text","value":"\#(value)","source":"request"}"# }
        let variant = origin.map { #","variant_of":"\#($0)","divergence_step":3"# } ?? ""
        return #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Save a file"},
             "steps":[{"step":1,"label":"Type the name"},{"step":2,"label":"Type the destination"},{"step":3,"label":"Confirm"}],
             "parameters":[\#(parameters.joined(separator: ","))],
             "uses":[{"step":1,"argument":"text","template":"{\#(first)}"},{"step":2,"argument":"text","template":"{\#(second)}"}]\#(variant)}
            """#
    }

    @Test("one parameter typed twice is not two independent ones: the variant is kept with its prefix suggested and why, in the version and the diagnosis; the same parameter renamed, with new values, is verified; a schema 4 archive's verified prefix is checked again on migration, its first record kept")
    func parametersCorrespond() async throws {
        let session = try Self.session()
        let tools = Learning.tools(session)
        let first = try await Self.attempt(tools, session, goal: "Save the report", text: "report", button: "Save")
        let originAnswer = try await Learning.task(tools, Self.interpretation(first, "file", "file", value: "report"))
        #expect(originAnswer["status"].string == "interpreted", "\(originAnswer)")
        let origin = ProcedureAssembly.routeID(candidateID: first, revision: 1)
        let second = try await Self.attempt(tools, session, goal: "Save the draft elsewhere", text: "draft", button: "Cancel")

        let split = try await Learning.task(tools, Self.interpretation(second, "input", "output", value: "draft", variantOf: origin))
        #expect(split["status"].string == "interpreted", "a variant whose prefix is not proven is kept: \(split)")
        let renamed = try await Learning.task(tools, Self.interpretation(second, "document", "document", value: "draft", variantOf: origin))
        #expect(renamed["status"].string == "interpreted" && renamed["revision"] == .number(2), "\(renamed)")

        let splitRoute = ProcedureAssembly.routeID(candidateID: second, revision: 1)
        let renamedRoute = ProcedureAssembly.routeID(candidateID: second, revision: 2)
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let splitVersion = try #require(try await memory.perform { try await $0.procedures.version(splitRoute) })
        let renamedVersion = try #require(try await memory.perform { try await $0.procedures.version(renamedRoute) })
        #expect(splitVersion.variantPrefix == VariantPrefix.Check(status: .suggested, comparedSteps: 2, reason: .parameterCorrespondence))
        #expect(renamedVersion.variantPrefix == VariantPrefix.Check(status: .verified, comparedSteps: 2, reason: nil))
        #expect(splitVersion.version.definition.parameters.count == 2 && renamedVersion.version.definition.parameters.count == 1)
        #expect(try Learning.rows("SELECT count(*) FROM memory_variant_prefixes", in: session) == ["0"],
                "schema 4's table is written no more")
        await memory.close()
        MemoryService.forget(session.directory)
        let taskID = try #require(try Learning.rows("SELECT task_id FROM memory_procedure_candidates WHERE candidate_id = '\(second)'",
                                                    in: session).first)
        let text = try ProcedureInspectionTests.inspection(taskID, session).text
        #expect(text.contains { $0.contains("revision 1 ") && $0.hasSuffix("prefix suggested over 2 steps (parameter_correspondence)") },
                "\(text.filter { $0.contains("version") })")
        #expect(text.contains { $0.contains("revision 2 ") && $0.hasSuffix("prefix verified over 2 steps") })

        // The same archive as the first correction's build wrote it: both prefixes stated verified, by a check
        // that did not match parameters. The migration checks them again; schema 4's rows stay as written.
        let url = session.directory.appendingPathComponent("memory.sqlite")
        try downgradeToSchema4(url)
        let raw = try SQLiteConnection(path: url.path)
        for route in [splitRoute, renamedRoute] {
            _ = try raw.run("""
                INSERT INTO memory_variant_prefixes (route_id, status, compared_steps, reason, checked_at_ms)
                VALUES (?, 'verified', 2, NULL, 1)
                """, [.text(route)])
        }
        raw.close()
        let reopened = MemoryService.shared(for: session.directory)
        _ = try await reopened.ready()
        #expect(await reopened.status().lastMigration?.contains("from schema 4") == true)
        #expect(try rawRows("PRAGMA user_version", at: url) == ["\(SQLiteMemorySchema.version)"])
        #expect(try rawRows("SELECT route_id || ':' || status || ':' || ifnull(reason, '-') FROM memory_variant_prefix_checks ORDER BY route_id",
                            at: url) == ["\(splitRoute):suggested:parameter_correspondence", "\(renamedRoute):verified:-"])
        #expect(try rawRows("SELECT status FROM memory_variant_prefixes ORDER BY route_id", at: url) == ["verified", "verified"],
                "the first check's record is kept as it was written")
        await reopened.close()
        MemoryService.forget(session.directory)
    }
}
