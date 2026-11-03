extension SchemaCoherence {
    struct ContextReference: Sendable {
        let child: String
        let parent: String
        let childKey: String
        let parentKey: String
        let columns: [(String, String)]

        init(_ child: String, _ parent: String, _ childKey: String, _ parentKey: String, _ columns: [(String, String)]) {
            self.child = child
            self.parent = parent
            self.childKey = childKey
            self.parentKey = parentKey
            self.columns = columns
        }

        var rule: SnapshotRule {
            let comparisons = columns.map { "r.\($0.0) IS p.\($0.1)" }.joined(separator: ",")
            let present = columns.map { "r.\($0.0) IS NOT NULL" }.joined(separator: " AND ")
            return SnapshotRule("context \(child).\(childKey)", """
                SELECT \(comparisons) FROM \(child) r LEFT JOIN \(parent) p ON p.\(parentKey)=r.\(childKey) WHERE \(present)
                """) { row in columns.indices.allSatisfy { row.integer($0) == 1 } }
        }
    }

    /// Preserves every historical composite FK's contextual columns after replacing its physical key.
    /// Identifiers are the frozen resources' columns, including the new surrogate owner of each composite parent.
    static let contextReferences: [ContextReference] = [
        ContextReference("brain_anchors", "brain_groups", "current_group_id", "group_id", [("app_id", "app_id"), ("current_group_id", "group_id")]),
        ContextReference("brain_scene_elements", "brain_anchors", "anchor_id", "anchor_id", [("app_id", "app_id"), ("anchor_id", "anchor_id")]),
        ContextReference("brain_scene_elements", "brain_scenes", "scene_id", "scene_id", [("app_id", "app_id"), ("scene_id", "scene_id")]),
        ContextReference("brain_scene_elements", "brain_scene_elements", "parent_element_id", "scene_element_id", [("scene_id", "scene_id"), ("parent_element_id", "scene_element_id")]),
        ContextReference("brain_group_members", "brain_anchors", "anchor_id", "anchor_id", [("app_id", "app_id"), ("anchor_id", "anchor_id")]),
        ContextReference("brain_group_members", "brain_groups", "group_id", "group_id", [("app_id", "app_id"), ("group_id", "group_id")]),
        ContextReference("brain_transitions", "brain_scene_elements", "scene_element_id", "scene_element_id", [("app_id", "app_id"), ("from_scene_id", "scene_id"), ("scene_element_id", "scene_element_id")]),
        ContextReference("brain_transitions", "brain_menu_commands", "menu_command_id", "menu_command_id", [("app_id", "app_id"), ("menu_command_id", "menu_command_id")]),
        ContextReference("brain_transitions", "brain_anchors", "anchor_id", "anchor_id", [("app_id", "app_id"), ("anchor_id", "anchor_id")]),
        ContextReference("brain_transitions", "brain_scenes", "to_scene_id", "scene_id", [("app_id", "app_id"), ("to_scene_id", "scene_id")]),
        ContextReference("brain_transitions", "brain_scenes", "from_scene_id", "scene_id", [("app_id", "app_id"), ("from_scene_id", "scene_id")]),
        ContextReference("memory_events", "brain_app_contexts", "context_id", "context_id", [("app_id", "app_id"), ("context_id", "context_id")]),
        ContextReference("memory_input_events", "memory_events", "event_id", "event_id", [("event_kind", "event_kind"), ("event_id", "event_id")]),
        ContextReference("memory_agent_actions", "memory_events", "event_id", "event_id", [("app_id", "app_id"), ("event_id", "event_id")]),
        ContextReference("memory_agent_actions", "memory_events", "event_id", "event_id", [("event_kind", "event_kind"), ("event_id", "event_id")]),
        ContextReference("memory_agent_action_windows", "memory_agent_action_applications", "listing_application_id", "listing_application_id", [("event_id", "event_id"), ("application_position", "position")]),
        ContextReference("memory_agent_action_observations", "memory_event_observations", "sample_observation_id", "observation_id", [("sample_observation_id", "observation_id"), ("sample_event_id", "event_id"), ("sample_phase", "phase"), ("sample_ordinal", "sample_ordinal"), ("sample_kind", "observation_kind")]),
        ContextReference("memory_event_observations", "memory_event_observations", "parent_observation_id", "observation_id", [("event_id", "event_id"), ("parent_observation_id", "observation_id")]),
        ContextReference("memory_event_scenes", "brain_scenes", "scene_id", "scene_id", [("app_id", "app_id"), ("scene_id", "scene_id")]),
        ContextReference("memory_event_scenes", "memory_events", "event_id", "event_id", [("app_id", "app_id"), ("event_id", "event_id")]),
        ContextReference("memory_verifications", "memory_events", "event_id", "event_id", [("event_kind", "event_kind"), ("event_id", "event_id")]),
        ContextReference("brain_applications", "brain_transitions", "transition_id", "transition_id", [("app_id", "app_id"), ("transition_id", "transition_id")]),
        ContextReference("brain_applications", "brain_anchors", "anchor_id", "anchor_id", [("app_id", "app_id"), ("anchor_id", "anchor_id")]),
        ContextReference("brain_applications", "memory_event_observations", "sample_observation_id", "observation_id", [("sample_observation_id", "observation_id"), ("event_id", "event_id"), ("phase", "phase"), ("sample_ordinal", "sample_ordinal"), ("sample_kind", "observation_kind")]),
        ContextReference("brain_applications", "memory_events", "event_id", "event_id", [("app_id", "app_id"), ("event_id", "event_id")]),
        ContextReference("brain_evidence", "brain_transitions", "transition_id", "transition_id", [("app_id", "app_id"), ("transition_id", "transition_id")]),
        ContextReference("brain_evidence", "brain_menu_commands", "menu_command_id", "menu_command_id", [("app_id", "app_id"), ("menu_command_id", "menu_command_id")]),
        ContextReference("brain_evidence", "brain_groups", "group_id", "group_id", [("app_id", "app_id"), ("group_id", "group_id")]),
        ContextReference("brain_evidence", "brain_scene_elements", "scene_element_id", "scene_element_id", [("app_id", "app_id"), ("scene_element_id", "scene_element_id")]),
        ContextReference("brain_evidence", "brain_anchors", "anchor_id", "anchor_id", [("app_id", "app_id"), ("anchor_id", "anchor_id")]),
        ContextReference("brain_evidence", "brain_scenes", "scene_id", "scene_id", [("app_id", "app_id"), ("scene_id", "scene_id")]),
        ContextReference("brain_evidence", "memory_events", "event_id", "event_id", [("app_id", "app_id"), ("event_id", "event_id")]),
        ContextReference("memory_step_checks", "memory_route_parameters", "expected_parameter_id", "parameter_id", [("route_id", "route_id"), ("expected_parameter_id", "parameter_id")]),
        ContextReference("memory_step_checks", "brain_anchors", "expected_anchor_id", "anchor_id", [("app_id", "app_id"), ("expected_anchor_id", "anchor_id")]),
        ContextReference("memory_step_checks", "brain_scenes", "expected_scene_id", "scene_id", [("app_id", "app_id"), ("expected_scene_id", "scene_id")]),
        ContextReference("memory_step_checks", "memory_route_steps", "step_id", "step_id", [("app_id", "app_id"), ("step_id", "step_id")]),
        ContextReference("memory_step_checks", "memory_route_steps", "step_id", "step_id", [("route_id", "route_id"), ("step_id", "step_id")]),
        ContextReference("memory_step_operations", "memory_step_operations", "parent_operation_id", "operation_id", [("step_id", "step_id"), ("parent_operation_id", "operation_id")]),
        ContextReference("memory_step_operations", "memory_route_steps", "step_id", "step_id", [("app_id", "app_id"), ("step_id", "step_id")]),
        ContextReference("memory_step_operations", "memory_route_steps", "step_id", "step_id", [("route_id", "route_id"), ("step_id", "step_id")]),
        ContextReference("memory_operation_arguments", "brain_applications", "brain_application_id", "application_id", [("app_id", "app_id"), ("brain_application_id", "application_id")]),
        ContextReference("memory_operation_arguments", "brain_menu_commands", "menu_command_id", "menu_command_id", [("app_id", "app_id"), ("menu_command_id", "menu_command_id")]),
        ContextReference("memory_operation_arguments", "brain_anchors", "anchor_id", "anchor_id", [("app_id", "app_id"), ("anchor_id", "anchor_id")]),
        ContextReference("memory_operation_arguments", "memory_agent_actions", "event_id", "event_id", [("app_id", "app_id"), ("event_id", "event_id")]),
        ContextReference("memory_operation_arguments", "memory_step_operations", "operation_id", "operation_id", [("app_id", "app_id"), ("operation_id", "operation_id")]),
        ContextReference("memory_operation_arguments", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id")]),
        ContextReference("memory_operation_arguments", "memory_step_operations", "operation_id", "operation_id", [("route_id", "route_id"), ("operation_id", "operation_id")]),
        ContextReference("memory_route_call_bindings", "memory_route_parameters", "source_parameter_id", "parameter_id", [("route_id", "route_id"), ("source_parameter_id", "parameter_id")]),
        ContextReference("memory_route_call_bindings", "memory_route_parameters", "called_parameter_id", "parameter_id", [("called_route_id", "route_id"), ("called_parameter_id", "parameter_id")]),
        ContextReference("memory_route_call_bindings", "memory_route_steps", "step_id", "step_id", [("route_id", "route_id"), ("step_id", "step_id"), ("called_route_id", "called_route_id")]),
        ContextReference("memory_step_evidence", "memory_step_occurrences", "step_occurrence_id", "step_occurrence_id", [("step_occurrence_id", "step_occurrence_id"), ("step_id", "step_id")]),
        ContextReference("memory_experiences", "memory_route_steps", "step_id", "step_id", [("route_id", "route_id"), ("step_id", "step_id")]),
        ContextReference("memory_experience_bindings", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id"), ("value_type", "value_type")]),
        ContextReference("memory_experience_bindings", "memory_experiences", "experience_id", "experience_id", [("route_id", "route_id"), ("experience_id", "experience_id")]),
        ContextReference("memory_task_constraints", "memory_task_revisions", "task_revision_id", "task_revision_id", [("task_id", "task_id"), ("revision", "revision")]),
        ContextReference("memory_task_message_refs", "memory_task_revisions", "task_revision_id", "task_revision_id", [("task_id", "task_id"), ("revision", "revision")]),
        ContextReference("memory_task_attempts", "memory_task_revisions", "task_revision_id", "task_revision_id", [("task_id", "task_id"), ("opened_at_revision", "revision")]),
        ContextReference("memory_task_checkpoints", "memory_task_revisions", "task_revision_id", "task_revision_id", [("task_id", "task_id"), ("revision", "revision")]),
        ContextReference("memory_task_checkpoints", "memory_task_attempts", "task_occurrence_id", "task_occurrence_id", [("task_occurrence_id", "task_occurrence_id"), ("task_id", "task_id")]),
        ContextReference("memory_task_values", "memory_task_checkpoints", "checkpoint_id", "checkpoint_id", [("task_occurrence_id", "task_occurrence_id"), ("checkpoint_sequence", "sequence")]),
        ContextReference("memory_task_values", "memory_task_revisions", "task_revision_id", "task_revision_id", [("task_id", "task_id"), ("revision", "revision")]),
        ContextReference("memory_task_call_revisions", "memory_task_revisions", "task_revision_id", "task_revision_id", [("task_id", "task_id"), ("revision", "revision")]),
        ContextReference("memory_task_call_revisions", "memory_task_attempts", "task_occurrence_id", "task_occurrence_id", [("task_occurrence_id", "task_occurrence_id"), ("task_id", "task_id")]),
        ContextReference("memory_operation_verification_samples", "memory_event_observations", "sample_observation_id", "observation_id", [("sample_observation_id", "observation_id"), ("sample_event_id", "event_id"), ("sample_phase", "phase"), ("sample_ordinal", "sample_ordinal"), ("sample_kind", "observation_kind")]),
        ContextReference("memory_procedure_candidates", "memory_task_checkpoints", "checkpoint_id", "checkpoint_id", [("task_occurrence_id", "task_occurrence_id"), ("checkpoint_sequence", "sequence")]),
        ContextReference("memory_procedure_candidates", "memory_task_attempts", "task_occurrence_id", "task_occurrence_id", [("task_occurrence_id", "task_occurrence_id"), ("task_id", "task_id")]),
        ContextReference("memory_procedure_versions", "memory_task_attempts", "task_occurrence_id", "task_occurrence_id", [("task_occurrence_id", "task_occurrence_id"), ("task_id", "task_id")]),
        ContextReference("memory_procedure_versions", "memory_procedure_candidates", "candidate_id", "candidate_id", [("candidate_id", "candidate_id"), ("task_occurrence_id", "task_occurrence_id")]),
        ContextReference("memory_procedure_parts", "memory_route_steps", "step_id", "step_id", [("route_id", "route_id"), ("step_id", "step_id")]),
        ContextReference("memory_procedure_parts", "memory_procedure_parts", "parent_part_id", "part_id", [("route_id", "route_id"), ("parent_part_id", "part_id")]),
        ContextReference("memory_part_contract_items", "brain_scenes", "scene_id", "scene_id", [("app_id", "app_id"), ("scene_id", "scene_id")]),
        ContextReference("memory_part_contract_items", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id")]),
        ContextReference("memory_part_contract_items", "memory_procedure_parts", "part_id", "part_id", [("route_id", "route_id"), ("part_id", "part_id")]),
        ContextReference("memory_parameter_details", "memory_procedure_parts", "produced_by_part_id", "part_id", [("route_id", "route_id"), ("produced_by_part_id", "part_id")]),
        ContextReference("memory_parameter_details", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id")]),
        ContextReference("memory_operation_argument_segments", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id")]),
        ContextReference("memory_operation_argument_segments", "memory_step_operations", "operation_id", "operation_id", [("route_id", "route_id"), ("operation_id", "operation_id")]),
        ContextReference("memory_parameter_bindings", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id")]),
        ContextReference("memory_procedure_step_occurrences", "memory_route_steps", "step_id", "step_id", [("route_id", "route_id"), ("step_id", "step_id")]),
        ContextReference("memory_part_qualification_reasons", "memory_part_qualifications", "qualification_id", "qualification_id", [("part_id", "part_id"), ("sequence", "sequence")]),
        ContextReference("memory_part_qualification_evidence", "memory_part_qualifications", "qualification_id", "qualification_id", [("part_id", "part_id"), ("sequence", "sequence")]),
        ContextReference("brain_relations", "brain_scene_elements", "scene_element_id", "scene_element_id", [("app_id", "app_id"), ("from_scene_id", "scene_id"), ("scene_element_id", "scene_element_id")]),
        ContextReference("brain_relations", "brain_scenes", "to_scene_id", "scene_id", [("app_id", "app_id"), ("to_scene_id", "scene_id")]),
        ContextReference("brain_relations", "brain_scenes", "from_scene_id", "scene_id", [("app_id", "app_id"), ("from_scene_id", "scene_id")]),
        ContextReference("brain_relations", "brain_app_contexts", "context_id", "context_id", [("app_id", "app_id"), ("context_id", "context_id")]),
        ContextReference("brain_scene_shapes", "brain_scenes", "scene_id", "scene_id", [("app_id", "app_id"), ("scene_id", "scene_id")]),
        ContextReference("brain_relation_evidence", "brain_relation_evaluations", "evaluation_id", "evaluation_id", [("call_event_id", "call_event_id"), ("sequence", "sequence")]),
        ContextReference("memory_recall_queries", "memory_task_attempts", "task_occurrence_id", "task_occurrence_id", [("task_occurrence_id", "task_occurrence_id"), ("task_id", "task_id")]),
        ContextReference("memory_recall_selections", "memory_recall_needs", "need_id", "need_id", [("query_id", "query_id"), ("need_position", "position")]),
        ContextReference("memory_recall_requirements", "memory_recall_selections", "selection_id", "selection_id", [("query_id", "query_id"), ("need_position", "need_position"), ("selection_position", "position")]),
        ContextReference("memory_recall_links", "memory_recall_needs", "need_id", "need_id", [("query_id", "query_id"), ("need_position", "position")]),
        ContextReference("memory_recall_reports", "memory_recall_needs", "need_id", "need_id", [("query_id", "query_id"), ("need_position", "position")]),
        ContextReference("memory_recall_proposals", "memory_task_attempts", "task_occurrence_id", "task_occurrence_id", [("task_occurrence_id", "task_occurrence_id"), ("task_id", "task_id")]),
        ContextReference("memory_recall_proposal_sources", "memory_recall_proposal_needs", "proposal_need_id", "proposal_need_id", [("proposal_id", "proposal_id"), ("need_position", "position")]),
        ContextReference("memory_recall_choice_needs", "memory_recall_needs", "need_id", "need_id", [("query_id", "query_id"), ("need_position", "position")]),
        ContextReference("memory_recall_choice_links", "memory_recall_selections", "selection_id", "selection_id", [("query_id", "query_id"), ("need_position", "need_position"), ("selection_position", "position")]),
        ContextReference("memory_recall_choice_links", "memory_recall_needs", "need_id", "need_id", [("query_id", "query_id"), ("need_position", "position")]),
        ContextReference("memory_operation_argument_fields", "memory_route_parameters", "parameter_id", "parameter_id", [("route_id", "route_id"), ("parameter_id", "parameter_id")]),
        ContextReference("memory_operation_argument_fields", "memory_step_operations", "operation_id", "operation_id", [("route_id", "route_id"), ("operation_id", "operation_id")]),
    ]
}
