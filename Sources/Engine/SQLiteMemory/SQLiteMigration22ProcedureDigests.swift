import Foundation
import Memory

/// SQLiteMigration22ProcedureDigests reconstructs canonical procedure content after every reference is converted.
/// Destination history guards are not installed yet. The temporary digest fields never survive a successful conversion.
enum SQLiteMigration22ProcedureDigests {
    static func convert(in db: SQLiteConnection) throws {
        let candidates = try db.prepare("SELECT candidate_id,policy_version FROM memory_procedure_candidates ORDER BY candidate_id")
        defer { candidates.finalize() }
        while try candidates.step() {
            try Task.checkCancellation()
            guard let id = candidates.row.integer(0), let policy = try candidates.row.text(1) else {
                throw refusal("candidate digest identity")
            }
            let steps = try db.query("""
                SELECT e.event_uuid,s.step_kind FROM memory_candidate_steps s
                JOIN memory_events e ON e.event_id=s.call_event_id WHERE s.candidate_id=? ORDER BY s.position
                """, [.integer(id)]) { (uuid: try $0.text(0) ?? "", kind: try $0.text(1) ?? "") }
            var canonical = policy
            for step in steps {
                canonical += "\n" + field(step.uuid)
                if policy == ProcedureSegmentation.mixedPolicyVersion { canonical += "\u{1F}" + step.kind }
            }
            try db.run("UPDATE memory_procedure_candidates SET structure_digest=? WHERE candidate_id=?",
                       [.blob(Array(Digest16.of(canonical))),.integer(id)])
        }
        let interpretations = try db.prepare("SELECT interpretation_id,candidate_id FROM memory_procedure_interpretations ORDER BY interpretation_id")
        defer { interpretations.finalize() }
        while try interpretations.step() {
            try Task.checkCancellation()
            guard let id = interpretations.row.integer(0), let candidate = interpretations.row.integer(1) else {
                throw refusal("interpretation digest identity")
            }
            let canonical = try interpretation(in: db, id: id, candidate: candidate).canonical
            try db.run("UPDATE memory_procedure_interpretations SET payload_digest=? WHERE interpretation_id=?",
                       [.blob(Array(Digest16.of(canonical))),.integer(id)])
        }
    }

    private struct Part {
        let id: Int64
        let reference: PartReference
        let label: String?
        let outcome: DeclaredPartOutcome?
    }

    private static func interpretation(in db: SQLiteConnection, id: Int64, candidate: Int64) throws -> ProcedureInterpretation {
        let versions = try db.query("""
            SELECT v.route_id,r.route_uuid,v.divergence_position FROM memory_procedure_versions v
            LEFT JOIN memory_routes r ON r.route_id=v.variant_of_route_id WHERE v.interpretation_id=?
            """, [.integer(id)]) { (route: $0.integer(0), variant: try $0.text(1), divergence: $0.integer(2)) }
        guard versions.count == 1, let version = versions.first, let route = version.route else {
            throw refusal("interpretation version")
        }
        let parts = try db.query("""
            SELECT part_id,part_uuid,part_kind,first_position,last_position,label,declared_outcome
            FROM memory_procedure_parts WHERE route_id=? ORDER BY part_id
            """, [.integer(route)]) { row -> Part in
                guard let part = row.integer(0), let uuid = try row.text(1), let kind = try row.text(2),
                      let first = row.integer(3), let last = row.integer(4),
                      let outcome = try row.text(6).flatMap(DeclaredPartOutcome.init(rawValue:)) else {
                    throw refusal("interpretation part")
                }
                let suffix = uuid.split(separator: "/").last.map(String.init) ?? ""
                let reference: PartReference
                switch kind {
                case "procedure": reference = .procedure
                case "step": reference = .step(Int(suffix.dropFirst("step-".count)) ?? Int(first))
                case "subprocedure":
                    if suffix.hasPrefix("block-"), let block = Int(suffix.dropFirst("block-".count)) {
                        reference = .block(block)
                    } else if suffix.hasPrefix("phase-") {
                        let bounds = suffix.dropFirst("phase-".count).split(separator: "-").compactMap { Int($0) }
                        guard bounds.count == 2 else { throw refusal("interpretation phase") }
                        reference = .phase(first: bounds[0], last: bounds[1])
                    } else { reference = .phase(first: Int(first), last: Int(last)) }
                default: throw refusal("interpretation part kind")
                }
                return Part(id: part, reference: reference, label: try row.text(5), outcome: outcome == .notDeclared ? nil : outcome)
            }
        let references = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0.reference) })
        let statements = try parts.map { try PartStatement(reference: $0.reference, label: $0.label, outcome: $0.outcome) }
        let parameters = try db.query("""
            SELECT p.name,p.direction,d.role,d.value_kind,d.unit,d.sensitivity,d.produced_by_part_id,
                   b.content,b.text_value,b.source,b.source_ref,b.source_version
            FROM memory_route_parameters p JOIN memory_parameter_details d ON d.parameter_id=p.parameter_id
            LEFT JOIN memory_parameter_bindings b ON b.parameter_id=p.parameter_id AND b.route_id=p.route_id
            WHERE p.route_id=? ORDER BY p.parameter_id
            """, [.integer(route)]) { row -> ParameterStatement in
                guard let name = try row.text(0), let direction = try row.text(1).flatMap(ParameterDirection.init(rawValue:)),
                      let role = try row.text(2), let kind = try row.text(3).flatMap(TaskValueKind.init(rawValue:)),
                      let sensitivity = try row.text(5).flatMap(TaskValueSensitivity.init(rawValue:)) else {
                    throw refusal("interpretation parameter")
                }
                let content: TaskValue.Content?
                switch try row.text(7) {
                case nil: content = nil
                case "text": content = .text(try row.text(8) ?? "")
                case "missing": content = .missing
                case "withheld": content = .withheld
                default: throw refusal("interpretation parameter content")
                }
                let produced: PartReference?
                if let part = row.integer(6) {
                    guard let reference = references[part] else { throw refusal("interpretation producing part") }
                    produced = reference
                } else { produced = nil }
                return try ParameterStatement(name: name, role: role, kind: kind, direction: direction, unit: row.text(4),
                                              sensitivity: sensitivity, content: content,
                                              source: row.text(9).flatMap(TaskValueSource.init(rawValue:)),
                                              sourceRef: row.text(10), sourceVersion: row.text(11), producedBy: produced)
            }
        let arguments = try db.query("""
            SELECT g.operation_id,g.argument_name,g.argument_position,min(s.position) FROM memory_operation_argument_segments g
            JOIN memory_step_operations o ON o.operation_id=g.operation_id JOIN memory_route_steps s ON s.step_id=o.step_id
            WHERE g.route_id=? GROUP BY g.operation_id,g.argument_name,g.argument_position ORDER BY s.position,g.argument_index
            """, [.integer(route)]) { (operation: $0.integer(0) ?? 0, name: try $0.text(1) ?? "",
                                       position: $0.integer(2) ?? 0, step: $0.integer(3) ?? 0) }
        let uses = try arguments.map { argument -> UseStatement in
            let pieces = try db.query("""
                SELECT g.segment_kind,g.literal_text,p.name FROM memory_operation_argument_segments g
                LEFT JOIN memory_route_parameters p ON p.parameter_id=g.parameter_id
                WHERE g.operation_id=? AND g.argument_name=? AND g.argument_position=? ORDER BY g.segment_position
                """, [.integer(argument.operation),.text(argument.name),.integer(argument.position)]) { row -> UsePiece in
                    switch try row.text(0) {
                    case "literal": return .literal(try row.text(1) ?? "")
                    case "parameter":
                        guard let name = try row.text(2) else { throw refusal("interpretation use parameter") }
                        return .parameter(name)
                    default: throw refusal("interpretation use segment")
                    }
                }
            return try UseStatement(stepPosition: Int(argument.step), argumentName: argument.name,
                                    argumentPosition: Int(argument.position), pieces: pieces)
        }
        return try ProcedureInterpretation(candidateID: String(candidate), parts: statements, parameters: parameters,
                                           uses: uses, variantOf: version.variant, divergencePosition: version.divergence.map(Int.init))
    }

    private static func field(_ text: String) -> String { "\(text.utf8.count):" + text }

    private static func refusal(_ reason: String) -> SQLiteMigration22.Refusal { .verificationFailed([reason]) }
}
