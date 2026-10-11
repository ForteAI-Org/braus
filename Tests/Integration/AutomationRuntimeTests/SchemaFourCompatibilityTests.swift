//
//  SchemaFourCompatibilityTests.swift
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

/// Brings an archive back to exactly schema 3, as the first D2 delivery wrote it: the objects schemas 4 and 5 add
/// are dropped, and what brain-relations-1 wrote is put back in schema 3's register, each call's latest
/// evaluation as its application and its evidence as its proofs, under that policy's name.
func downgradeToSchema3(_ url: URL) throws {
    let raw = try SQLiteConnection(path: url.path)
    defer { raw.close() }
    try raw.execute("PRAGMA foreign_keys = OFF")
    try raw.execute(
        """
        INSERT INTO brain_relation_applications (call_event_id, app_id, policy_version, outcome, reason, applied_at_ms)
        SELECT v.call_event_id, v.app_id, 'brain-relations-1', v.outcome,
               CASE v.reason WHEN 'awaiting_state' THEN 'no_before_state' WHEN 'indistinct_element' THEN 'ambiguous_element'
                             ELSE v.reason END, v.evaluated_at_ms
        FROM brain_relation_evaluations v
        WHERE v.sequence = (SELECT max(w.sequence) FROM brain_relation_evaluations w WHERE w.call_event_id = v.call_event_id)
        """
    )
    try raw.execute(
        """
        INSERT INTO brain_relation_proofs (relation_id, call_event_id, relation, verification_event_id, policy_version, assessed_at_ms)
        SELECT e.relation_id, e.call_event_id, e.relation, e.verification_event_id, 'brain-relations-1', e.assessed_at_ms
        FROM brain_relation_evidence e
        WHERE e.sequence = (SELECT max(w.sequence) FROM brain_relation_evaluations w WHERE w.call_event_id = e.call_event_id)
        """
    )
    for object in try SQLiteMemorySchema.objectsAdded(since: 3) { try raw.execute("DROP \(object.type.uppercased()) \(object.name)") }
    try raw.execute("DELETE FROM memory_schema_migrations WHERE to_version > 3")
    try raw.execute("INSERT OR IGNORE INTO memory_schema_migrations (to_version, from_version, migrated_at_ms) VALUES (3, 0, 0)")
    try raw.execute("PRAGMA user_version = 3")
}

/// An archive of schema 3 written by the first D2 delivery (procedures, a variant, brain-relations-1's register)
/// opens in this build: migrated after its copy, every row of schema 3 kept, the variant's prefix stated as
/// never verified, the anchors keyed, and every call the first policy applied evaluated again under this one by
/// the service's own recovery, its register left as it was.
@MainActor
@Suite("An archive of schema 3 opens at the current schema, keeping what it holds", .serialized)
struct SchemaFourCompatibilityTests {

    typealias Learning = ProcedureLearningTests

    @Test("a schema 3 archive with procedures, a variant and the first policy's register migrates, keeps every row and is evaluated again under this policy")
    func schemaThreeArchive() async throws {
        let session = Learning.photoSession(try W.directory())
        let tools = Learning.tools(session)
        _ = try await Learning.task(tools, #"{"operation":"begin","goal":"Export the photo"}"#)
        try await Learning.runPhotoExport(tools, session)
        let first = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let origin = try #require(first["candidate"]["id"].string)
        _ = try await Learning.task(tools, Learning.photoInterpretation(origin))
        _ = try await Learning.task(tools, #"{"operation":"begin","goal":"Export it again"}"#)
        try await Learning.runPhotoExport(tools, session)
        let second = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(second["candidate"]["id"].string)
        let variant = try await Learning.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)","procedure":{"label":"Export the photo again"},
             "variant_of":"\#(ProcedureAssembly.routeID(candidateID: origin, revision: 1))","divergence_step":8}
            """#)
        #expect(variant["status"].string == "interpreted", "\(variant)")
        let memory = MemoryService.shared(for: session.directory)
        #expect(await memory.flush(within: .seconds(10)))
        let catalogue = try await memory.perform { try await $0.procedures.catalogue(limit: 200) }.map(\.part.partID)
        await memory.close()
        MemoryService.forget(session.directory)

        let url = session.directory.appendingPathComponent("memory.sqlite")
        try downgradeToSchema3(url)
        let tables = SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.text(of: 3))
        func counts() throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try tables.map { ($0, try rawRows("SELECT count(*) FROM \($0)", at: url).first ?? "") })
        }
        let before = try counts()
        #expect(Int(before["brain_relation_applications"] ?? "0") ?? 0 > 0, "the first policy's register holds the calls")

        let reopened = MemoryService.shared(for: session.directory)
        _ = try await reopened.ready()
        #expect(try rawRows("PRAGMA user_version", at: url) == ["\(SQLiteMemorySchema.version)"])
        #expect(await reopened.status().lastMigration?.contains("from schema 3") == true)
        #expect(await reopened.flush(within: .seconds(20)))
        var after = try counts()
        #expect(Int(after["memory_schema_migrations"] ?? "") == (Int(before["memory_schema_migrations"] ?? "") ?? 0) + 1)
        #expect((Int(after["brain_relations"] ?? "") ?? 0) >= (Int(before["brain_relations"] ?? "") ?? 0),
                "relations this policy keys otherwise are added beside the first policy's, none removed")
        for table in ["memory_schema_migrations", "brain_relations"] { after[table] = before[table] }
        #expect(after == before, "every row of schema 3 is kept: \(before.filter { after[$0.key] != $0.value })")
        #expect(try rawRows("SELECT status || ':' || ifnull(reason, '-') FROM memory_variant_prefixes", at: url)
                == ["suggested:declared_before_verification"], "a variant built before prefixes were checked says so")
        #expect(try rawRows("SELECT status || ':' || ifnull(reason, '-') FROM memory_variant_prefix_checks", at: url)
                == ["suggested:declared_before_verification"], "and schema 5 takes that check as it is")
        #expect(Int(try rawRows("SELECT count(*) FROM brain_anchor_label_keys", at: url).first ?? "0") ?? 0 > 0)
        let status = await reopened.status()
        let applied = Int(before["brain_relation_applications"] ?? "0") ?? 0
        #expect(status.relationRecovery.reevaluated == applied && !status.relationRecoveryPending, "\(status.relationRecovery)")
        let causes = try rawRows("""
            SELECT DISTINCT cause FROM brain_relation_evaluations v
            WHERE v.sequence = 1 AND v.call_event_id IN (SELECT call_event_id FROM brain_relation_applications)
            """, at: url)
        #expect(causes == ["policy"], "the calls the first policy applied are evaluated again under this one, as such")
        let relations = try await reopened.perform { try await $0.relations.relations(of: Learning.finder) }
        #expect(relations.contains { $0.key.elementKey == "item_template|files|AXRow|" && $0.supports == 2 && $0.standing == .exposed })
        #expect(try await reopened.perform { try await $0.procedures.catalogue(limit: 200) }.map(\.part.partID) == catalogue,
                "the catalogue offers what it offered")
        await reopened.close()
        MemoryService.forget(session.directory)
    }
}
