extension SchemaCoherence {
    /// These guards compare a mutation's old and new facts, which a final snapshot cannot recover.
    static let mutationRuleNames: Set<String> = [
        "memory_event_observations_capture_identity_guard", "memory_event_observations_capture_status_guard",
        "memory_event_observations_capture_delete_guard", "memory_operation_arguments_application_sealed",
        "memory_operation_arguments_application_immutable", "memory_operation_arguments_application_kept",
        "memory_qualification_policies_forward", "memory_recall_generations_born_building",
        "memory_recall_generations_transitions", "memory_recall_generations_kept", "memory_recall_documents_immutable",
        "memory_recall_vectors_immutable", "memory_recall_entries_immutable", "memory_recall_work_progress", "memory_recall_work_kept"
    ]

    static var snapshotRuleNames: Set<String> {
        Set((scopeSnapshotRules + callSnapshotRules + historySnapshotRules + procedureSnapshotRules + recallSnapshotRules).map(\.name))
            .union(["memory_route_steps_no_recursive_calls", "memory_step_operations_no_parent_cycle"])
    }

    static var recallSnapshotRules: [SnapshotRule] {
        var rules: [SnapshotRule] = []
        rules.append(SnapshotRule("memory_recall_vectors_shape", """
            SELECT length(v.vector),s.dimensions,s.precision FROM memory_recall_vectors v LEFT JOIN memory_recall_spaces s USING(space_int_id)
            """) { try memoryRecallVectorsShape($0.integer(0) ?? 0, $0.integer(1), $0.text(2)) })
        rules.append(SnapshotRule("memory_recall_entries_valid", """
            SELECT e.route_id,p.route_id,e.part_kind,p.part_kind,d.document_format,g.document_format
            FROM memory_recall_entries e LEFT JOIN memory_procedure_parts p USING(part_id)
            LEFT JOIN memory_recall_documents d USING(document_id) LEFT JOIN memory_recall_generations g USING(generation_id)
            """) { try memoryRecallEntriesValid("ready", $0.integer(0) ?? 0, $0.integer(1), $0.text(2) ?? "", $0.text(3), $0.text(4), $0.text(5)) })
        rules.append(SnapshotRule("memory_recall_selections_valid", """
            SELECT s.route_id,s.first_position,s.last_position,
                   (SELECT max(last_position) FROM memory_procedure_parts WHERE route_id=s.route_id),
                   s.whole_part_id,p.route_id,p.part_kind,p.first_position,p.last_position,s.role,n.coverage
            FROM memory_recall_selections s LEFT JOIN memory_procedure_parts p ON p.part_id=s.whole_part_id
            LEFT JOIN memory_recall_needs n USING(need_id)
            """) { row in
                let part: Part? = try row.integer(5).map {
                    try Part(route: $0, kind: row.text(6) ?? "", first: row.integer(7) ?? 0, last: row.integer(8) ?? 0)
                }
                return try memoryRecallSelectionsValid(row.integer(0) ?? 0, row.integer(1) ?? 0, row.integer(2) ?? 0,
                    row.integer(3), row.integer(4), part, row.text(9) ?? "", row.text(10))
            })
        for (table, accepts) in [("memory_recall_links", memoryRecallLinksValid), ("memory_recall_choice_links", memoryRecallChoiceLinksValid)] {
            let selected = table == "memory_recall_choice_links" ? "AND s.selection_id=r.selection_id" : ""
            rules.append(SnapshotRule(table + "_valid", """
                SELECT EXISTS(SELECT 1 FROM memory_task_events t JOIN memory_recall_queries q USING(task_occurrence_id)
                              WHERE q.query_id=r.query_id AND t.event_id=r.call_event_id AND t.role='action'),
                       r.step_position,EXISTS(SELECT 1 FROM memory_recall_selections s WHERE s.query_id=r.query_id
                           AND s.need_id=r.need_id AND s.role='selected' \(selected)
                           AND r.step_position BETWEEN s.first_position AND s.last_position)
                FROM \(table) r
                """) { accepts($0.integer(0) == 1, $0.integer(1), $0.integer(2) == 1) })
        }
        rules.append(SnapshotRule("memory_recall_reports_in_order", """
            SELECT sequence,lag(sequence) OVER (PARTITION BY need_id ORDER BY sequence) FROM memory_recall_reports
            """) { memoryRecallReportsInOrder($0.integer(0) ?? 0, $0.integer(1)) })
        rules.append(SnapshotRule("memory_recall_proposal_sources_named", """
            SELECT s.source_key,s.route_id,p.source_key,p.route_id FROM memory_recall_proposal_sources s
            JOIN memory_recall_proposal_sources p USING(proposal_id)
            """) { try memoryRecallProposalSourcesNamed($0.text(0) ?? "", $0.integer(1) ?? 0, [($0.text(2) ?? "", $0.integer(3) ?? 0)]) })
        rules.append(SnapshotRule("memory_recall_choices_valid", """
            SELECT q.task_id,q.task_occurrence_id,q.task_revision,q.source,q.source_stream_id,
                   p.task_id,p.task_occurrence_id,p.task_revision,p.source,p.source_stream_id
            FROM memory_recall_choices c LEFT JOIN memory_recall_queries q USING(query_id) LEFT JOIN memory_recall_proposals p USING(proposal_id)
            """) { row in
                func owner(_ offset: Int) throws -> RecallOwner? {
                    guard let task = row.integer(offset), let attempt = row.integer(offset+1), let revision = row.integer(offset+2),
                          let source = try row.text(offset+3), let stream = try row.text(offset+4) else { return nil }
                    return RecallOwner(task: task, attempt: attempt, revision: revision, source: source, stream: stream)
                }
                return try memoryRecallChoicesValid(owner(0), owner(5))
            })
        rules.append(SnapshotRule("memory_recall_choice_needs_valid", """
            SELECT r.declared,(SELECT count(*) FROM memory_recall_selections s WHERE s.need_id=r.need_id AND s.role='selected'),
                   (SELECT count(*) FROM memory_recall_selections s WHERE s.need_id=r.need_id AND s.role='alternative'),n.coverage
            FROM memory_recall_choice_needs r LEFT JOIN memory_recall_needs n USING(need_id)
            """) { try memoryRecallChoiceNeedsValid($0.text(0) ?? "", $0.integer(1) ?? 0, $0.integer(2) ?? 0, $0.text(3)) })
        rules.append(SnapshotRule("memory_recall_links_not_of_choices", """
            SELECT EXISTS(SELECT 1 FROM memory_recall_choices c WHERE c.query_id=r.query_id) FROM memory_recall_links r
            """) { memoryRecallLinksNotOfChoices($0.integer(0) == 1) })
        rules.append(SnapshotRule("memory_recall_requirements_valid", """
            SELECT r.kind,r.step_position,r.step_position BETWEEN s.first_position AND s.last_position,
                   EXISTS(SELECT 1 FROM memory_recall_selections e WHERE e.need_id=s.need_id AND e.route_id=s.route_id
                          AND e.position<s.position AND e.role='selected' AND s.role='selected'
                          AND r.step_position BETWEEN e.first_position AND e.last_position),
                   EXISTS(SELECT 1 FROM memory_procedure_parts p WHERE p.route_id=s.route_id AND p.part_kind='step'
                          AND p.first_position=r.step_position),r.step_position<s.first_position,s.role,r.parameter_id IS NOT NULL,
                   EXISTS(SELECT 1 FROM memory_route_parameters p WHERE p.route_id=s.route_id AND p.parameter_id=r.parameter_id)
            FROM memory_recall_requirements r LEFT JOIN memory_recall_selections s USING(selection_id)
            """) { try memoryRecallRequirementsValid(RecallRequirement(
                kind: $0.text(0) ?? "", step: $0.integer(1), inSelection: $0.integer(2) == 1, inEarlierSelection: $0.integer(3) == 1,
                isVersionStep: $0.integer(4) == 1, beforeSelection: $0.integer(5) == 1, selectionRole: $0.text(6),
                hasParameter: $0.integer(7) == 1, parameterInVersion: $0.integer(8) == 1)) })
        return rules
    }
}
