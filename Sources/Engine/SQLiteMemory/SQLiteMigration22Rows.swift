import Foundation
import Memory

/// SQLiteMigration22Rows transfers every unified-19 table before installing destination guards.
/// It borrows both transactions and refuses any count difference. New derived tables have explicit producers only.
enum SQLiteMigration22Rows {
    struct Report {
        let rowsByTable: [String: Int]
        let outcomes: SQLiteMigration22Outcomes.Report
        let observationsConverted: Int
        let commandStepsConverted: Int
        let personFactsLeftInSource: Int
    }

    private static func temporaryDigest(identity: String) -> SQLiteMigration22RowCopy.Field {
        .derived { row in
            guard case .text(let value) = row[identity] else {
                throw SQLiteMigration22.Refusal.verificationFailed(["temporary digest identity"])
            }
            return .blob(Array(Digest16.of("migration-22:" + identity + ":" + value)))
        }
    }

    static func copy(
        from source: SQLiteConnection,
        into target: SQLiteConnection,
        at nowMS: Int64,
        faults: MigrationFaults = .none,
        progress: (SQLiteMigration22.Phase, Int, Int) -> Void = { _, _, _ in }
    ) throws -> Report {
        let plan = try SQLiteMigration22Plan(source: source, target: target)
        let content = try SQLiteMigration22Content(source: source, target: target, plan: plan)
        let total = try plan.tables.reduce(0) { sum, table in
            sum + Int(try source.query("SELECT count(*) FROM \(table)") { $0.integer(0) ?? 0 }.first ?? 0)
        }
        var done = 0
        progress(.copying, done, total)
        var counts: [String: Int] = [:]
        for table in plan.tables {
            var fields = try content.fields(for: table)
            // Both canonical digests need complete reference families. They are replaced before verification and commit.
            if table == "memory_procedure_candidates" { fields["structure_digest"] = temporaryDigest(identity: "candidate_id") }
            if table == "memory_procedure_interpretations" { fields["payload_digest"] = temporaryDigest(identity: "interpretation_id") }
            counts[table] = try SQLiteMigration22RowCopy.copy(
                table, from: source, into: target, keys: plan.keys, fields: plan.fields(for: table, overriding: fields),
                progress: { progress(.copying, done + $0, total) }
            )
            done += counts[table] ?? 0
        }
        let version = try source.query("PRAGMA user_version") { $0.integer(0) }.first ?? nil
        let commands = version == 20 || version == 21 ? try SQLiteMigration22Commands.convert(in: target) : 0
        let facts = version == 21
            ? (try source.query("SELECT count(*) FROM memory_learned_facts") { Int($0.integer(0) ?? 0) }.first ?? 0) : 0
        try SQLiteMigration22ProcedureDigests.convert(in: target)
        progress(.convertingObservations, done, total)
        try faults.hit(.phase(.convertingObservations))
        // The frozen indexes are installed after population. These construction-only indexes prevent
        // per-capture scans while content and sets are interned, then leave no destination schema change.
        let constructionIndexes = [
            ("migration22_observation_children", "memory_event_observations(parent_observation_id,observation_kind,observation_id)"),
            ("migration22_element_digest", "memory_elements(digest) WHERE replaced_by_id IS NULL"),
            ("migration22_set_digest", "memory_element_sets(digest) WHERE replaced_by_id IS NULL"),
            ("migration22_scene_elements", "brain_scene_elements(scene_id,scene_element_id)")
        ]
        for (name, columns) in constructionIndexes { try target.execute("CREATE INDEX \(name) ON \(columns)") }
        let observations = try SQLiteMigration22Observations.convert(in: target)
        for (name, _) in constructionIndexes { try target.execute("DROP INDEX \(name)") }
        progress(.convertingOutcomes, done, total)
        try faults.hit(.phase(.convertingOutcomes))
        let outcomes = try SQLiteMigration22Outcomes.convert(from: source, into: target)
        try target.run("INSERT INTO memory_consolidation_queue(job_kind,ref_id,enqueued_at_ms) VALUES ('index_rebuild',0,?)",
                       [.integer(nowMS)])
        for (table, count) in counts {
            let found = try target.query("SELECT count(*) FROM \(table)") { $0.integer(0) }.first ?? nil
            guard found == Int64(count) else {
                throw SQLiteMigration22.Refusal.verificationFailed(["row count \(table)"])
            }
        }
        return Report(rowsByTable: counts, outcomes: outcomes, observationsConverted: observations,
                      commandStepsConverted: commands, personFactsLeftInSource: facts)
    }
}
