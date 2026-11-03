extension SchemaCoherence {
    static var procedureSnapshotRules: [SnapshotRule] {
        var rules: [SnapshotRule] = []
        rules.append(SnapshotRule("memory_candidate_steps_operation", """
            SELECT s.position,s.block_index,s.app_id,a.app_id,s.step_kind,s.actor,a.tool_kind,a.execution_status,
                   c.task_occurrence_id,s.step_occurrence_id,
                   EXISTS(SELECT 1 FROM memory_task_events e WHERE e.task_occurrence_id=c.task_occurrence_id
                          AND e.event_id=s.call_event_id AND e.role='action'),
                   EXISTS(SELECT 1 FROM memory_step_events e WHERE e.step_occurrence_id=s.step_occurrence_id
                          AND e.event_id=s.call_event_id AND e.role='action'),
                   (SELECT max(p.position) FROM memory_candidate_steps p WHERE p.candidate_id=s.candidate_id AND p.position<s.position),
                   p.block_index,p.app_id,s.segment_id IS NOT NULL,
                   EXISTS(SELECT 1 FROM memory_call_capabilities k WHERE k.event_id=s.call_event_id)
            FROM memory_candidate_steps s LEFT JOIN memory_procedure_candidates c USING(candidate_id)
            LEFT JOIN memory_agent_actions a ON a.event_id=s.call_event_id
            LEFT JOIN memory_candidate_steps p ON p.candidate_id=s.candidate_id AND p.position=s.position-1
            """) { row in
                let attempt = row.integer(8) ?? 0
                let occurrence = row.integer(9)
                return try memoryCandidateStepsOperation(CandidateStep(
                    position: row.integer(0) ?? 0, block: row.integer(1) ?? 0, app: row.integer(2), callApp: row.integer(3),
                    kind: row.text(4) ?? "", actor: row.text(5) ?? "", tool: row.text(6), status: row.text(7),
                    attempt: attempt, callAttempts: row.integer(10) == 1 ? [attempt] : [], occurrence: occurrence,
                    callOccurrences: row.integer(11) == 1 ? occurrence.map { [$0] } ?? [] : [],
                    lastPosition: row.integer(12), previousBlock: row.integer(13), previousApp: row.integer(14),
                    hasPersonSegment: row.integer(15) == 1, hasCapability: row.integer(16) == 1))
            })
        rules.append(SnapshotRule("memory_procedure_interpretations_in_order", """
            SELECT revision,lag(revision) OVER (PARTITION BY candidate_id ORDER BY revision) FROM memory_procedure_interpretations
            """) { memoryProcedureInterpretationsInOrder($0.integer(0) ?? 0, $0.integer(1)) })
        rules.append(SnapshotRule("memory_procedure_versions_insert_guard", """
            SELECT r.candidate_id,i.candidate_id,r.variant_of_route_id,r.divergence_position,
                   (SELECT count(*) FROM memory_route_steps s WHERE s.route_id=r.variant_of_route_id)
            FROM memory_procedure_versions r LEFT JOIN memory_procedure_interpretations i USING(interpretation_id)
            """) { memoryProcedureVersionsInsertGuard($0.integer(0) ?? 0, $0.integer(1), $0.integer(2), $0.integer(3), $0.integer(4)) })
        rules.append(SnapshotRule("memory_procedure_parts_containment", """
            SELECT r.route_id,r.part_kind,r.first_position,r.last_position,r.parent_part_id,
                   p.route_id,p.part_kind,p.first_position,p.last_position FROM memory_procedure_parts r
            LEFT JOIN memory_procedure_parts p ON p.part_id=r.parent_part_id
            """) { row in
                let child = try Part(route: row.integer(0) ?? 0, kind: row.text(1) ?? "", first: row.integer(2) ?? 0, last: row.integer(3) ?? 0)
                let parent: Part? = try row.integer(5).map {
                    try Part(route: $0, kind: row.text(6) ?? "", first: row.integer(7) ?? 0, last: row.integer(8) ?? 0)
                }
                return memoryProcedurePartsContainment(child, parent, row.integer(4))
            })
        rules.append(SnapshotRule("memory_procedure_parts_step_position", """
            SELECT p.part_kind,p.first_position,s.position FROM memory_procedure_parts p LEFT JOIN memory_route_steps s USING(step_id)
            """) { try memoryProcedurePartsStepPosition($0.text(0) ?? "", $0.integer(1) ?? 0, $0.integer(2)) })
        rules.append(SnapshotRule("memory_operation_argument_segments_alone", """
            SELECT EXISTS(SELECT 1 FROM memory_operation_arguments a WHERE a.operation_id=g.operation_id
                          AND a.argument_name=g.argument_name AND a.position=g.argument_position)
            FROM memory_operation_argument_segments g
            """) { memoryOperationArgumentSegmentsAlone($0.integer(0) == 1) })
        rules.append(SnapshotRule("memory_operation_arguments_not_templated", """
            SELECT a.operation_id,EXISTS(SELECT 1 FROM memory_operation_argument_segments g WHERE g.operation_id=a.operation_id
                                        AND g.argument_name=a.argument_name AND g.argument_position=a.position)
            FROM memory_operation_arguments a
            """) { memoryOperationArgumentsNotTemplated($0.integer(0), $0.integer(1) == 1) })
        rules.append(SnapshotRule("memory_parameter_bindings_secret", """
            SELECT b.content,d.sensitivity FROM memory_parameter_bindings b LEFT JOIN memory_parameter_details d USING(parameter_id)
            """) { try memoryParameterBindingsSecret($0.text(0) ?? "", $0.text(1)) })
        rules.append(SnapshotRule("memory_part_qualifications_in_order", """
            SELECT sequence,lag(sequence) OVER (PARTITION BY part_id ORDER BY sequence) FROM memory_part_qualifications
            """) { memoryPartQualificationsInOrder($0.integer(0) ?? 0, $0.integer(1)) })
        rules.append(SnapshotRule("memory_part_qualification_reasons_refused_only", """
            SELECT q.verdict FROM memory_part_qualification_reasons r LEFT JOIN memory_part_qualifications q USING(qualification_id)
            """) { try memoryPartQualificationReasonsRefusedOnly($0.text(0)) })
        rules.append(SnapshotRule("memory_part_qualification_evidence_own_call", """
            SELECT r.call_event_id,v.call_event_id FROM memory_part_qualification_evidence r
            LEFT JOIN memory_operation_verifications v ON v.event_id=r.verification_event_id
            """) { memoryPartQualificationEvidenceOwnCall($0.integer(0) ?? 0, $0.integer(1)) })
        rules.append(SnapshotRule("memory_part_states_in_order", """
            SELECT sequence,lag(sequence) OVER (PARTITION BY part_id ORDER BY sequence),
                   lag(state) OVER (PARTITION BY part_id ORDER BY sequence) FROM memory_part_states
            """) { try memoryPartStatesInOrder($0.integer(0) ?? 0, $0.integer(1), $0.text(2)) })
        rules.append(SnapshotRule("brain_relations_not_app_scope", """
            SELECT f.scene_kind,t.scene_kind FROM brain_relations r LEFT JOIN brain_scenes f ON f.scene_id=r.from_scene_id
            LEFT JOIN brain_scenes t ON t.scene_id=r.to_scene_id
            """) { try brainRelationsNotAppScope($0.text(0), $0.text(1)) })
        rules.append(SnapshotRule("brain_relation_proofs_own_call", """
            SELECT p.call_event_id,v.call_event_id,a.app_id,r.app_id FROM brain_relation_proofs p
            LEFT JOIN memory_operation_verifications v ON v.event_id=p.verification_event_id
            LEFT JOIN memory_agent_actions a ON a.event_id=p.call_event_id LEFT JOIN brain_relations r USING(relation_id)
            """) { brainRelationProofsOwnCall($0.integer(0) ?? 0, $0.integer(1), $0.integer(2), $0.integer(3)) })
        rules.append(SnapshotRule("brain_scene_shapes_not_app_scope", """
            SELECT s.scene_kind FROM brain_scene_shapes r LEFT JOIN brain_scenes s USING(scene_id)
            """) { try brainSceneShapesNotAppScope($0.text(0)) })
        rules.append(SnapshotRule("brain_relation_evaluations_in_order", """
            SELECT r.sequence,lag(r.sequence) OVER (PARTITION BY r.call_event_id ORDER BY r.sequence),r.app_id,a.app_id
            FROM brain_relation_evaluations r LEFT JOIN memory_agent_actions a ON a.event_id=r.call_event_id
            """) { brainRelationEvaluationsInOrder($0.integer(0) ?? 0, $0.integer(1), $0.integer(2), $0.integer(3)) })
        rules.append(SnapshotRule("brain_relation_evidence_own_call", """
            SELECT p.call_event_id,v.call_event_id,a.app_id,r.app_id,p.relation,e.outcome FROM brain_relation_evidence p
            LEFT JOIN memory_operation_verifications v ON v.event_id=p.verification_event_id
            LEFT JOIN memory_agent_actions a ON a.event_id=p.call_event_id LEFT JOIN brain_relations r USING(relation_id)
            LEFT JOIN brain_relation_evaluations e USING(evaluation_id)
            """) { try brainRelationEvidenceOwnCall($0.integer(0) ?? 0, $0.integer(1), $0.integer(2), $0.integer(3), $0.text(4) ?? "", $0.text(5)) })
        rules.append(SnapshotRule("brain_anchor_label_keys_own_app", """
            SELECT r.app_id,a.app_id FROM brain_anchor_label_keys r LEFT JOIN brain_anchors a USING(anchor_id)
            """) { brainAnchorLabelKeysOwnApp($0.integer(0) ?? 0, $0.integer(1)) })
        for (table, accepts) in [("memory_variant_prefixes", memoryVariantPrefixesOfVariants),
                                 ("memory_variant_prefix_checks", memoryVariantPrefixChecksOfVariants)] {
            rules.append(SnapshotRule(table + "_of_variants", """
                SELECT v.variant_of_route_id,v.divergence_position,r.compared_steps FROM \(table) r LEFT JOIN memory_procedure_versions v USING(route_id)
                """) { accepts($0.integer(0), $0.integer(1), $0.integer(2) ?? 0) })
        }
        rules.append(SnapshotRule("memory_call_argument_fields_reference", """
            SELECT f.field_kind,EXISTS(SELECT 1 FROM memory_call_result_fields r
                JOIN memory_task_events s ON s.event_id=f.source_event_id AND s.role='action'
                JOIN memory_task_events c ON c.event_id=f.event_id AND c.role='action' AND c.task_occurrence_id=s.task_occurrence_id
                WHERE r.event_id=f.source_event_id AND r.field_path=f.source_path AND r.withheld_reason IS NULL AND s.position<c.position)
            FROM memory_call_argument_fields f
            """) { try memoryCallArgumentFieldsReference($0.text(0) ?? "", $0.integer(1) == 1) })
        rules.append(SnapshotRule("memory_operation_argument_fields_one_form", """
            SELECT EXISTS(SELECT 1 FROM memory_operation_arguments a WHERE a.operation_id=f.operation_id
                          AND a.argument_name=f.argument_name AND a.position=f.argument_position),
                   EXISTS(SELECT 1 FROM memory_operation_argument_segments g WHERE g.operation_id=f.operation_id
                          AND g.argument_name=f.argument_name AND g.argument_position=f.argument_position),
                   f.field_kind,f.source_step_position,
                   (SELECT p.first_position FROM memory_procedure_parts p JOIN memory_route_steps rs USING(step_id)
                    JOIN memory_step_operations o ON o.step_id=rs.step_id AND o.route_id=rs.route_id
                    WHERE o.operation_id=f.operation_id AND p.part_kind='step' AND p.route_id=rs.route_id)
            FROM memory_operation_argument_fields f
            """) { try memoryOperationArgumentFieldsOneForm($0.integer(0) == 1, $0.integer(1) == 1, $0.text(2) ?? "", $0.integer(3), $0.integer(4)) })
        rules.append(SnapshotRule("memory_call_reconciliations_order", """
            SELECT r.sequence,lag(r.sequence) OVER (PARTITION BY r.event_id ORDER BY r.sequence),r.evidence_event_id,
                   e.execution_status,e.started_at_ms,c.started_at_ms FROM memory_call_reconciliations r
            LEFT JOIN memory_agent_actions e ON e.event_id=r.evidence_event_id LEFT JOIN memory_agent_actions c ON c.event_id=r.event_id
            """) { try memoryCallReconciliationsOrder($0.integer(0) ?? 0, $0.integer(1), $0.integer(2), $0.text(3), $0.integer(4), $0.integer(5)) })
        return rules
    }
}
