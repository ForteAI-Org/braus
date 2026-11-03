import Foundation

extension SchemaCoherence {
    struct SnapshotRule {
        let name: String
        let sql: String
        let accepts: (SQLiteStatement.Row) throws -> Bool

        init(_ name: String, _ sql: String, _ accepts: @escaping (SQLiteStatement.Row) throws -> Bool) {
            self.name = name
            self.sql = sql
            self.accepts = accepts
        }
    }

    /// Checks saved relationships in one borrowed snapshot, returning deterministic trigger names.
    /// Mutation guards need both old and new facts and are checked by writers; final rows cannot reconstruct those facts.
    static func check(_ snapshot: some SQLiteQuerying) throws -> [String] {
        var failures: Set<String> = []
        let rules = scopeSnapshotRules + callSnapshotRules + historySnapshotRules + procedureSnapshotRules + recallSnapshotRules
            + contextReferences.map(\.rule)
        for rule in rules {
            _ = try snapshot.query(rule.sql, []) { row in
                if try !rule.accepts(row) { failures.insert(rule.name) }
            }
        }
        let routes = try snapshot.query("SELECT route_id,called_route_id FROM memory_route_steps WHERE called_route_id IS NOT NULL", []) {
            ($0.integer(0) ?? 0, $0.integer(1) ?? 0)
        }
        let edges = Dictionary(grouping: routes, by: { $0.0 }).mapValues { $0.map(\.1) }
        if routes.contains(where: { !memoryRouteStepsNoRecursiveCalls($0.0, $0.1, edges) }) {
            failures.insert("memory_route_steps_no_recursive_calls")
        }
        let operations = try snapshot.query("SELECT operation_id,parent_operation_id FROM memory_step_operations", []) {
            ($0.integer(0) ?? 0, $0.integer(1))
        }
        let parents = Dictionary(uniqueKeysWithValues: operations.compactMap { id, parent in parent.map { (id, $0) } })
        if operations.contains(where: { !memoryStepOperationsNoParentCycle($0.0, $0.1, parents) }) {
            failures.insert("memory_step_operations_no_parent_cycle")
        }
        return failures.sorted()
    }

    static var scopeSnapshotRules: [SnapshotRule] {
        scopeChecks.sorted { $0.key < $1.key }.map { name, accepts in
            let table: String
            let reference: String
            if name.hasPrefix("brain_transitions_to_") {
                table = "brain_transitions"
                reference = "to_scene_id"
            } else {
                table = String(name.components(separatedBy: "_not_app_scope")[0])
                reference = "scene_id"
            }
            return SnapshotRule(name, "SELECT s.scene_kind FROM \(table) r LEFT JOIN brain_scenes s ON s.scene_id=r.\(reference)") {
                accepts(try $0.text(0))
            }
        }
    }

    static var callSnapshotRules: [SnapshotRule] {
        var rules: [SnapshotRule] = []
        rules.append(SnapshotRule("memory_agent_actions_app_from_event_insert", """
            SELECT a.app_id,e.app_id FROM memory_agent_actions a LEFT JOIN memory_events e USING(event_id)
            """) { memoryAgentActionsAppFromEventInsert($0.integer(0), $0.integer(1)) })
        for (table, prefix, checks) in [
            ("memory_step_operations", "memory_step_operations_app_from_step", [memoryStepOperationsAppFromStepInsert, memoryStepOperationsAppFromStepUpdate]),
            ("memory_step_checks", "memory_step_checks_app_from_step", [memoryStepChecksAppFromStepInsert, memoryStepChecksAppFromStepUpdate])
        ] {
            for (suffix, accepts) in zip(["insert", "update"], checks) {
                rules.append(SnapshotRule(prefix + "_" + suffix, "SELECT r.app_id,s.app_id FROM \(table) r LEFT JOIN memory_route_steps s USING(step_id)") {
                    accepts($0.integer(0), $0.integer(1))
                })
            }
        }
        for (suffix, accepts) in zip(["insert", "update"], [memoryOperationArgumentsAppFromOwnerInsert, memoryOperationArgumentsAppFromOwnerUpdate]) {
            rules.append(SnapshotRule("memory_operation_arguments_app_from_owner_" + suffix, """
                SELECT r.app_id,r.operation_id,o.app_id,r.event_id,a.app_id FROM memory_operation_arguments r
                LEFT JOIN memory_step_operations o USING(operation_id) LEFT JOIN memory_agent_actions a USING(event_id)
                """) { accepts($0.integer(0), $0.integer(1), $0.integer(2), $0.integer(3), $0.integer(4)) })
        }
        for (table, name, accepts) in [
            ("memory_agent_action_effect_labels", "memory_agent_action_effect_labels_insert_guard", memoryAgentActionEffectLabelsInsertGuard),
            ("memory_agent_action_status", "memory_agent_action_status_insert_guard", memoryAgentActionStatusInsertGuard),
            ("memory_agent_action_observations", "memory_agent_action_observations_insert_guard", memoryAgentActionObservationsInsertGuard)
        ] {
            rules.append(SnapshotRule(name, """
                SELECT a.tool_kind,a.execution_status,a.result_kind,a.observed_effect_kind FROM \(table) r
                LEFT JOIN memory_agent_actions a USING(event_id)
                """) { row in accepts(try savedAction(row)) })
        }
        rules.append(SnapshotRule("memory_agent_action_listings_insert_guard", """
            SELECT a.tool_kind,a.execution_status,a.result_kind,a.observed_effect_kind,r.listing_kind
            FROM memory_agent_action_listings r LEFT JOIN memory_agent_actions a USING(event_id)
            """) { try memoryAgentActionListingsInsertGuard(savedAction($0), $0.text(4) ?? "") })
        rules.append(SnapshotRule("memory_agent_action_applications_insert_guard", """
            SELECT l.listing_kind,r.pid,r.is_running,r.app_version,r.location,r.is_default_browser
            FROM memory_agent_action_applications r LEFT JOIN memory_agent_action_listings l USING(event_id)
            """) { row in
                try memoryAgentActionApplicationsInsertGuard(row.text(0), ListingApplication(
                    pid: row.integer(1), isRunning: row.integer(2).map { $0 != 0 }, appVersion: row.text(3),
                    location: row.text(4), isDefaultBrowser: row.integer(5).map { $0 != 0 }))
            })
        rules.append(SnapshotRule("memory_agent_action_windows_insert_guard", """
            SELECT l.listing_kind FROM memory_agent_action_windows r LEFT JOIN memory_agent_action_listings l USING(event_id)
            """) { try memoryAgentActionWindowsInsertGuard($0.text(0)) })
        for (suffix, accepts) in zip(["insert", "update"], [memoryStepEventsVerificationRoleInsert, memoryStepEventsVerificationRoleUpdate]) {
            rules.append(SnapshotRule("memory_step_events_verification_role_" + suffix, """
                SELECT r.role,r.step_occurrence_id,v.step_occurrence_id FROM memory_step_events r LEFT JOIN memory_verifications v USING(event_id)
                """) { try accepts($0.text(0) ?? "", $0.integer(1) ?? 0, $0.integer(2)) })
        }
        for (suffix, accepts) in zip(["insert", "update"], [memoryVerificationsMatchesMembershipInsert, memoryVerificationsMatchesMembershipUpdate]) {
            rules.append(SnapshotRule("memory_verifications_matches_membership_" + suffix, """
                SELECT v.step_occurrence_id,r.step_occurrence_id FROM memory_verifications v
                JOIN memory_step_events r ON r.event_id=v.event_id AND r.role='verification'
                """) { accepts($0.integer(0), [$0.integer(1)]) })
        }
        for (suffix, accepts) in zip(["insert", "update"], [memoryActionCorrelationsRolesInsert, memoryActionCorrelationsRolesUpdate]) {
            rules.append(SnapshotRule("memory_action_correlations_roles_" + suffix, """
                SELECT w.source,w.event_kind,a.source,a.event_kind FROM memory_action_correlations r
                LEFT JOIN memory_events w ON w.event_id=r.watcher_event_id LEFT JOIN memory_events a ON a.event_id=r.agent_event_id
                """) { try accepts(Event(source: $0.text(0) ?? "", kind: $0.text(1) ?? ""),
                                     Event(source: $0.text(2) ?? "", kind: $0.text(3) ?? "")) })
        }
        let concluded: [(String, (String?) -> Bool)] = [
            ("memory_call_effects", memoryCallEffectsConcludedCall), ("memory_call_routes", memoryCallRoutesConcludedCall),
            ("memory_call_adapter_dispatches", memoryCallAdapterDispatchesConcludedCall), ("memory_call_rungs", memoryCallRungsConcludedCall),
            ("memory_call_route_advice", memoryCallRouteAdviceConcludedCall), ("memory_call_recording_gaps", memoryCallRecordingGapsConcludedCall),
            ("memory_call_argument_fields", memoryCallArgumentFieldsConcludedCall), ("memory_call_result_fields", memoryCallResultFieldsConcludedCall),
            ("memory_call_data_contexts", memoryCallDataContextsConcludedCall)
        ]
        for (table, accepts) in concluded {
            rules.append(SnapshotRule(table + "_concluded_call", "SELECT a.execution_status FROM \(table) r LEFT JOIN memory_agent_actions a USING(event_id)") {
                try accepts($0.text(0))
            })
        }
        rules.append(SnapshotRule("memory_operation_verifications_call_scope", """
            SELECT v.scope FROM memory_operation_verifications r LEFT JOIN memory_verifications v USING(event_id)
            """) { try memoryOperationVerificationsCallScope($0.text(0)) })
        return rules
    }

    static var historySnapshotRules: [SnapshotRule] {
        var rules: [SnapshotRule] = []
        for (suffix, accepts) in zip(["insert", "update"], [memoryEventScenesRequireCaptureInsert, memoryEventScenesRequireCaptureUpdate]) {
            rules.append(SnapshotRule("memory_event_scenes_require_capture_" + suffix, """
                SELECT s.match_status,o.status FROM memory_event_scenes s LEFT JOIN memory_event_observations o
                  ON o.event_id=s.event_id AND o.phase=s.phase AND o.sample_ordinal=s.sample_ordinal AND o.observation_kind='capture'
                """) { try accepts($0.text(0) ?? "", $0.text(1)) })
        }
        rules.append(SnapshotRule("brain_applications_insert_guard", """
            SELECT EXISTS(SELECT 1 FROM memory_operation_arguments a WHERE a.brain_application_id=r.application_id),
                   r.operation,e.event_kind,r.anchor_id,r.transition_id,t.anchor_id
            FROM brain_applications r LEFT JOIN memory_events e USING(event_id) LEFT JOIN brain_transitions t USING(transition_id)
            """) { try brainApplicationsInsertGuard($0.integer(0) == 1, $0.text(1) ?? "", $0.text(2), $0.integer(3), $0.integer(4), $0.integer(5)) })
        rules.append(SnapshotRule("memory_task_revisions_in_order", """
            SELECT revision,lag(revision) OVER (PARTITION BY task_id ORDER BY revision) FROM memory_task_revisions
            """) { memoryTaskRevisionsInOrder($0.integer(0) ?? 0, $0.integer(1)) })
        rules.append(SnapshotRule("memory_task_attempts_resume_same_task", """
            SELECT r.task_id,r.resumes_task_occurrence_id,p.task_id FROM memory_task_attempts r
            LEFT JOIN memory_task_attempts p ON p.task_occurrence_id=r.resumes_task_occurrence_id
            """) { memoryTaskAttemptsResumeSameTask($0.integer(0) ?? 0, $0.integer(1), $0.integer(2)) })
        rules.append(SnapshotRule("memory_task_checkpoints_in_order", """
            SELECT sequence,lag(sequence) OVER (PARTITION BY task_occurrence_id ORDER BY sequence),
                   EXISTS(SELECT 1 FROM memory_task_checkpoints p WHERE p.task_occurrence_id=r.task_occurrence_id
                          AND p.sequence<r.sequence AND p.checkpoint_kind='end') FROM memory_task_checkpoints r
            """) { memoryTaskCheckpointsInOrder($0.integer(0) ?? 0, $0.integer(1), $0.integer(2) == 1) })
        return rules
    }

    static func savedAction(_ row: SQLiteStatement.Row) throws -> Action? {
        guard let tool = try row.text(0), let status = try row.text(1) else { return nil }
        return try Action(tool: tool, status: status, result: row.text(2), effect: row.text(3))
    }
}
