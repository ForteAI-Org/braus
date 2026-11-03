/// SchemaCoherence checks contextual relationships outside the physical schema.
/// Every predicate is pure. Callers supply saved facts from the same transaction as their write.
enum SchemaCoherence {
    struct Action {
        var tool: String
        var status: String
        var result: String? = nil
        var effect: String? = nil
    }

    struct Event {
        let source: String
        let kind: String
    }

    struct ListingApplication {
        var pid: Int64? = nil
        var isRunning: Bool? = nil
        var appVersion: String? = nil
        var location: String? = nil
        var isDefaultBrowser: Bool? = nil
    }

    static let scopeChecks: [String: @Sendable (String?) -> Bool] = [
        "brain_scene_elements_not_app_scope_insert": brainSceneElementsNotAppScopeInsert,
        "brain_scene_elements_not_app_scope_update": brainSceneElementsNotAppScopeUpdate,
        "brain_scene_roles_not_app_scope_insert": brainSceneRolesNotAppScopeInsert,
        "brain_scene_roles_not_app_scope_update": brainSceneRolesNotAppScopeUpdate,
        "brain_scene_labels_not_app_scope_insert": brainSceneLabelsNotAppScopeInsert,
        "brain_scene_labels_not_app_scope_update": brainSceneLabelsNotAppScopeUpdate,
        "memory_event_scenes_not_app_scope_insert": memoryEventScenesNotAppScopeInsert,
        "memory_event_scenes_not_app_scope_update": memoryEventScenesNotAppScopeUpdate,
        "brain_evidence_not_app_scope_insert": brainEvidenceNotAppScopeInsert,
        "brain_evidence_not_app_scope_update": brainEvidenceNotAppScopeUpdate,
        "brain_transitions_to_not_app_scope_insert": brainTransitionsToNotAppScopeInsert,
        "brain_transitions_to_not_app_scope_update": brainTransitionsToNotAppScopeUpdate
    ]

    /// Replaces brain_scene_elements_not_app_scope_insert.
    static func brainSceneElementsNotAppScopeInsert(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_scene_elements_not_app_scope_update.
    static func brainSceneElementsNotAppScopeUpdate(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_scene_roles_not_app_scope_insert.
    static func brainSceneRolesNotAppScopeInsert(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_scene_roles_not_app_scope_update.
    static func brainSceneRolesNotAppScopeUpdate(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_scene_labels_not_app_scope_insert.
    static func brainSceneLabelsNotAppScopeInsert(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_scene_labels_not_app_scope_update.
    static func brainSceneLabelsNotAppScopeUpdate(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces memory_event_scenes_not_app_scope_insert.
    static func memoryEventScenesNotAppScopeInsert(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces memory_event_scenes_not_app_scope_update.
    static func memoryEventScenesNotAppScopeUpdate(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_evidence_not_app_scope_insert.
    static func brainEvidenceNotAppScopeInsert(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_evidence_not_app_scope_update.
    static func brainEvidenceNotAppScopeUpdate(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_transitions_to_not_app_scope_insert.
    static func brainTransitionsToNotAppScopeInsert(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_transitions_to_not_app_scope_update.
    static func brainTransitionsToNotAppScopeUpdate(_ kind: String?) -> Bool { kind != "app" }

    /// Replaces memory_agent_actions_app_from_event_insert.
    static func memoryAgentActionsAppFromEventInsert(_ app: Int64?, _ eventApp: Int64?) -> Bool { app == eventApp }
    /// Replaces memory_step_operations_app_from_step_insert.
    static func memoryStepOperationsAppFromStepInsert(_ app: Int64?, _ stepApp: Int64?) -> Bool { app == stepApp }
    /// Replaces memory_step_operations_app_from_step_update.
    static func memoryStepOperationsAppFromStepUpdate(_ app: Int64?, _ stepApp: Int64?) -> Bool { app == stepApp }
    /// Replaces memory_step_checks_app_from_step_insert.
    static func memoryStepChecksAppFromStepInsert(_ app: Int64?, _ stepApp: Int64?) -> Bool { app == stepApp }
    /// Replaces memory_step_checks_app_from_step_update.
    static func memoryStepChecksAppFromStepUpdate(_ app: Int64?, _ stepApp: Int64?) -> Bool { app == stepApp }

    /// Replaces memory_operation_arguments_app_from_owner_insert.
    static func memoryOperationArgumentsAppFromOwnerInsert(
        _ app: Int64?, _ operation: Int64?, _ operationApp: Int64?, _ event: Int64?, _ eventApp: Int64?
    ) -> Bool {
        (operation == nil || app == operationApp) && (event == nil || app == eventApp)
    }

    /// Replaces memory_operation_arguments_app_from_owner_update.
    static func memoryOperationArgumentsAppFromOwnerUpdate(
        _ app: Int64?, _ operation: Int64?, _ operationApp: Int64?, _ event: Int64?, _ eventApp: Int64?
    ) -> Bool {
        memoryOperationArgumentsAppFromOwnerInsert(app, operation, operationApp, event, eventApp)
    }

    /// Replaces memory_agent_action_effect_labels_insert_guard.
    static func memoryAgentActionEffectLabelsInsertGuard(_ action: Action?) -> Bool {
        guard let action, let effect = action.effect else { return false }
        return action.status == "completed" && ["menuOpened", "elementsAppeared", "elementsDisappeared"].contains(effect)
    }

    /// Replaces memory_agent_action_status_insert_guard.
    static func memoryAgentActionStatusInsertGuard(_ action: Action?) -> Bool {
        action?.status == "completed" && action?.tool == "status" && action?.result == "status"
    }

    /// Replaces memory_agent_action_listings_insert_guard.
    static func memoryAgentActionListingsInsertGuard(_ action: Action?, _ kind: String) -> Bool {
        action?.status == "completed" && action?.tool == kind && action?.result == "listing"
    }

    /// Replaces memory_agent_action_applications_insert_guard.
    static func memoryAgentActionApplicationsInsertGuard(_ kind: String?, _ entry: ListingApplication) -> Bool {
        switch kind {
        case "windows":
            entry.pid != nil && entry.isRunning == nil && entry.appVersion == nil
                && entry.location == nil && entry.isDefaultBrowser == nil
        case "apps": entry.pid == nil && entry.isRunning != nil
        default: false
        }
    }

    /// Replaces memory_agent_action_windows_insert_guard.
    static func memoryAgentActionWindowsInsertGuard(_ kind: String?) -> Bool { kind == "windows" }

    /// Replaces memory_agent_action_observations_insert_guard.
    static func memoryAgentActionObservationsInsertGuard(_ action: Action?) -> Bool {
        action?.status == "completed" && ["open_session", "observe"].contains(action?.tool ?? "") && action?.result == "observation"
    }

    /// Replaces memory_step_events_verification_role_insert.
    static func memoryStepEventsVerificationRoleInsert(_ role: String, _ occurrence: Int64, _ verificationOccurrence: Int64?) -> Bool {
        role != "verification" || occurrence == verificationOccurrence
    }

    /// Replaces memory_step_events_verification_role_update.
    static func memoryStepEventsVerificationRoleUpdate(_ role: String, _ occurrence: Int64, _ verificationOccurrence: Int64?) -> Bool {
        memoryStepEventsVerificationRoleInsert(role, occurrence, verificationOccurrence)
    }

    /// Replaces memory_verifications_matches_membership_insert.
    static func memoryVerificationsMatchesMembershipInsert(_ occurrence: Int64?, _ memberships: [Int64?]) -> Bool {
        memberships.allSatisfy { $0 == occurrence }
    }

    /// Replaces memory_verifications_matches_membership_update.
    static func memoryVerificationsMatchesMembershipUpdate(_ occurrence: Int64?, _ memberships: [Int64?]) -> Bool {
        memoryVerificationsMatchesMembershipInsert(occurrence, memberships)
    }

    /// Replaces memory_action_correlations_roles_insert.
    static func memoryActionCorrelationsRolesInsert(_ watcher: Event?, _ agent: Event?) -> Bool {
        watcher?.source == "watcher" && watcher?.kind == "input"
            && ["app", "cli", "mcp"].contains(agent?.source ?? "") && agent?.kind == "action"
    }

    /// Replaces memory_action_correlations_roles_update.
    static func memoryActionCorrelationsRolesUpdate(_ watcher: Event?, _ agent: Event?) -> Bool {
        memoryActionCorrelationsRolesInsert(watcher, agent)
    }

    /// Replaces memory_route_steps_no_recursive_calls.
    static func memoryRouteStepsNoRecursiveCalls(_ route: Int64, _ called: Int64?, _ edges: [Int64: [Int64]]) -> Bool {
        guard let called else { return true }
        return !reaches(route, startingAt: called, edges: edges)
    }

    /// Replaces memory_step_operations_no_parent_cycle.
    static func memoryStepOperationsNoParentCycle(_ operation: Int64, _ parent: Int64?, _ parents: [Int64: Int64]) -> Bool {
        guard let parent else { return true }
        return !reaches(operation, startingAt: parent, edges: parents.mapValues { [$0] })
    }

    struct CaptureKey: Equatable {
        let event: Int64
        let phase: String
        let ordinal: Int64
    }

    /// Replaces memory_event_scenes_require_capture_insert.
    static func memoryEventScenesRequireCaptureInsert(_ match: String, _ captureStatus: String?) -> Bool {
        captureStatus != nil && (match != "confirmed" || captureStatus == "complete")
    }

    /// Replaces memory_event_scenes_require_capture_update.
    static func memoryEventScenesRequireCaptureUpdate(_ match: String, _ captureStatus: String?) -> Bool {
        memoryEventScenesRequireCaptureInsert(match, captureStatus)
    }

    /// Replaces memory_event_observations_capture_identity_guard.
    static func memoryEventObservationsCaptureIdentityGuard(
        _ oldKind: String, _ oldKey: CaptureKey, _ kind: String, _ key: CaptureKey, _ referenced: Bool
    ) -> Bool {
        oldKind != "capture" || !referenced || (kind == "capture" && key == oldKey)
    }

    /// Replaces memory_event_observations_capture_status_guard.
    static func memoryEventObservationsCaptureStatusGuard(_ oldKind: String, _ status: String, _ confirmed: Bool) -> Bool {
        oldKind != "capture" || !confirmed || status == "complete"
    }

    /// Replaces memory_event_observations_capture_delete_guard.
    static func memoryEventObservationsCaptureDeleteGuard(_ oldKind: String, _ referenced: Bool) -> Bool {
        oldKind != "capture" || !referenced
    }

    /// Replaces brain_applications_insert_guard.
    static func brainApplicationsInsertGuard(
        _ hasArguments: Bool, _ operation: String, _ eventKind: String?,
        _ anchor: Int64?, _ transition: Int64?, _ transitionAnchor: Int64?
    ) -> Bool {
        hasArguments && (!["record", "set_name"].contains(operation) || eventKind == "action")
            && (transition == nil || anchor == transitionAnchor)
    }

    /// Replaces memory_operation_arguments_application_sealed.
    static func memoryOperationArgumentsApplicationSealed(_ application: Int64?, _ applicationExists: Bool) -> Bool {
        application == nil || !applicationExists
    }

    /// Replaces memory_operation_arguments_application_immutable.
    static func memoryOperationArgumentsApplicationImmutable(_ oldApplication: Int64?, _ application: Int64?) -> Bool {
        oldApplication == nil && application == nil
    }

    /// Replaces memory_operation_arguments_application_kept.
    static func memoryOperationArgumentsApplicationKept(_ application: Int64?) -> Bool { application == nil }

    /// Replaces memory_task_revisions_in_order.
    static func memoryTaskRevisionsInOrder(_ revision: Int64, _ previous: Int64?) -> Bool { isNext(revision, after: previous) }

    /// Replaces memory_task_attempts_resume_same_task.
    static func memoryTaskAttemptsResumeSameTask(_ task: Int64, _ resumed: Int64?, _ resumedTask: Int64?) -> Bool {
        resumed == nil || task == resumedTask
    }

    /// Replaces memory_task_checkpoints_in_order.
    static func memoryTaskCheckpointsInOrder(_ sequence: Int64, _ previous: Int64?, _ hasEnd: Bool) -> Bool {
        isNext(sequence, after: previous) && !hasEnd
    }

    /// Replaces memory_call_effects_concluded_call.
    static func memoryCallEffectsConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_routes_concluded_call.
    static func memoryCallRoutesConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_adapter_dispatches_concluded_call.
    static func memoryCallAdapterDispatchesConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_rungs_concluded_call.
    static func memoryCallRungsConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_route_advice_concluded_call.
    static func memoryCallRouteAdviceConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_operation_verifications_call_scope.
    static func memoryOperationVerificationsCallScope(_ scope: String?) -> Bool { scope == "call" }
    /// Replaces memory_call_recording_gaps_concluded_call.
    static func memoryCallRecordingGapsConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_argument_fields_concluded_call.
    static func memoryCallArgumentFieldsConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_result_fields_concluded_call.
    static func memoryCallResultFieldsConcludedCall(_ status: String?) -> Bool { concluded(status) }
    /// Replaces memory_call_data_contexts_concluded_call.
    static func memoryCallDataContextsConcludedCall(_ status: String?) -> Bool { concluded(status) }

    struct CandidateStep {
        var position: Int64 = 0
        var block: Int64 = 0
        var app: Int64? = nil
        var callApp: Int64? = nil
        var kind: String = "operation"
        var actor: String = "agent"
        var tool: String?
        var status: String?
        var attempt: Int64
        var callAttempts: [Int64]
        var occurrence: Int64?
        var callOccurrences: [Int64]
        var lastPosition: Int64? = nil
        var previousBlock: Int64? = nil
        var previousApp: Int64? = nil
        var hasPersonSegment: Bool = false
        var hasCapability: Bool = false
    }

    /// Replaces memory_candidate_steps_operation, retaining the new person's and capability row forms.
    static func memoryCandidateStepsOperation(_ step: CandidateStep) -> Bool {
        guard isNext(step.position, after: step.lastPosition, first: 0) else { return false }
        if step.position == 0 {
            guard step.block == 0 else { return false }
        } else {
            guard let previous = step.previousBlock else { return false }
            if step.app == step.previousApp {
                guard step.block == previous else { return false }
            } else {
                guard previous != Int64.max, step.block == previous + 1 else { return false }
            }
        }
        if step.actor == "person" { return step.hasPersonSegment }
        guard step.actor == "agent", let tool = step.tool, let status = step.status,
              !["planned", "skipped"].contains(status), step.callAttempts.contains(step.attempt),
              let occurrence = step.occurrence, step.callOccurrences.contains(occurrence), step.app == step.callApp else {
            return false
        }
        switch step.kind {
        case "operation": return ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu", "menu", "press"].contains(tool)
        case "adapter_call", "required_read": return tool == "app_call"
        case "capability_call": return step.hasCapability
        default: return false
        }
    }

    /// Replaces memory_procedure_interpretations_in_order.
    static func memoryProcedureInterpretationsInOrder(_ revision: Int64, _ previous: Int64?) -> Bool {
        isNext(revision, after: previous)
    }

    /// Replaces memory_procedure_versions_insert_guard.
    static func memoryProcedureVersionsInsertGuard(
        _ candidate: Int64, _ interpretationCandidate: Int64?, _ variant: Int64?, _ divergence: Int64?, _ variantStepCount: Int64?
    ) -> Bool {
        guard candidate == interpretationCandidate else { return false }
        guard variant != nil else { return true }
        guard let divergence else { return false }
        return divergence <= (variantStepCount ?? 0)
    }

    struct Part {
        let route: Int64
        let kind: String
        let first: Int64
        let last: Int64
    }

    /// Replaces memory_procedure_parts_containment.
    static func memoryProcedurePartsContainment(_ part: Part, _ parent: Part?, _ parentID: Int64?) -> Bool {
        guard parentID != nil else { return true }
        guard let parent, part.route == parent.route, parent.first <= part.first, part.last <= parent.last else { return false }
        return (parent.kind == "procedure" && ["subprocedure", "step"].contains(part.kind))
            || (parent.kind == "subprocedure" && part.kind == "step")
    }

    /// Replaces memory_procedure_parts_step_position.
    static func memoryProcedurePartsStepPosition(_ kind: String, _ first: Int64, _ stepPosition: Int64?) -> Bool {
        kind != "step" || first == stepPosition
    }

    /// Replaces memory_operation_argument_segments_alone.
    static func memoryOperationArgumentSegmentsAlone(_ hasScalarRow: Bool) -> Bool { !hasScalarRow }
    /// Replaces memory_operation_arguments_not_templated.
    static func memoryOperationArgumentsNotTemplated(_ operation: Int64?, _ hasTemplate: Bool) -> Bool {
        operation == nil || !hasTemplate
    }

    /// Replaces memory_parameter_bindings_secret.
    static func memoryParameterBindingsSecret(_ content: String, _ sensitivity: String?) -> Bool {
        content != "text" || sensitivity != "secret"
    }

    /// Replaces memory_part_qualifications_in_order.
    static func memoryPartQualificationsInOrder(_ sequence: Int64, _ previous: Int64?) -> Bool { isNext(sequence, after: previous) }
    /// Replaces memory_part_qualification_reasons_refused_only.
    static func memoryPartQualificationReasonsRefusedOnly(_ verdict: String?) -> Bool { verdict != "admitted" }
    /// Replaces memory_part_qualification_evidence_own_call.
    static func memoryPartQualificationEvidenceOwnCall(_ call: Int64, _ verifiedCall: Int64?) -> Bool { call == verifiedCall }
    /// Replaces memory_part_states_in_order.
    static func memoryPartStatesInOrder(_ sequence: Int64, _ previous: Int64?, _ previousState: String?) -> Bool {
        isNext(sequence, after: previous) && previousState != "retired"
    }

    /// Replaces memory_qualification_policies_forward.
    static func memoryQualificationPoliciesForward(_ oldVersion: String, _ version: String, _ oldTime: Int64, _ time: Int64) -> Bool {
        oldVersion.utf8.elementsEqual(version.utf8) && time >= oldTime
    }

    /// Replaces brain_relations_not_app_scope.
    static func brainRelationsNotAppScope(_ fromKind: String?, _ intoKind: String?) -> Bool { fromKind != "app" && intoKind != "app" }
    /// Replaces brain_relation_proofs_own_call.
    static func brainRelationProofsOwnCall(_ call: Int64, _ verifiedCall: Int64?, _ callApp: Int64?, _ relationApp: Int64?) -> Bool {
        call == verifiedCall && callApp == relationApp
    }

    /// Replaces brain_scene_shapes_not_app_scope.
    static func brainSceneShapesNotAppScope(_ kind: String?) -> Bool { kind != "app" }
    /// Replaces brain_relation_evaluations_in_order.
    static func brainRelationEvaluationsInOrder(_ sequence: Int64, _ previous: Int64?, _ app: Int64?, _ callApp: Int64?) -> Bool {
        isNext(sequence, after: previous) && (app == nil || app == callApp)
    }

    /// Replaces brain_relation_evidence_own_call.
    static func brainRelationEvidenceOwnCall(
        _ call: Int64, _ verifiedCall: Int64?, _ callApp: Int64?, _ relationApp: Int64?, _ relation: String, _ evaluation: String?
    ) -> Bool {
        brainRelationProofsOwnCall(call, verifiedCall, callApp, relationApp)
            && evaluation == (relation == "supports" ? "supported" : "contradicted")
    }

    /// Replaces brain_anchor_label_keys_own_app.
    static func brainAnchorLabelKeysOwnApp(_ app: Int64, _ anchorApp: Int64?) -> Bool { app == anchorApp }
    /// Replaces memory_variant_prefixes_of_variants.
    static func memoryVariantPrefixesOfVariants(_ variant: Int64?, _ divergence: Int64?, _ compared: Int64) -> Bool {
        guard variant != nil, let divergence else { return false }
        return compared <= divergence
    }

    /// Replaces memory_variant_prefix_checks_of_variants.
    static func memoryVariantPrefixChecksOfVariants(_ variant: Int64?, _ divergence: Int64?, _ compared: Int64) -> Bool {
        memoryVariantPrefixesOfVariants(variant, divergence, compared)
    }

    private static func concluded(_ status: String?) -> Bool {
        // Missing parents are checked by foreign keys; SQL NOT IN does not reject NULL.
        status.map { ["completed", "failed", "cancelled", "interrupted"].contains($0) } ?? true
    }

    static func isNext(_ number: Int64, after previous: Int64?, first: Int64 = 1) -> Bool {
        let prior = previous ?? (first - 1)
        return prior != Int64.max && number == prior + 1
    }

    private static func reaches(_ target: Int64, startingAt first: Int64, edges: [Int64: [Int64]]) -> Bool {
        var pending = [first]
        var visited: Set<Int64> = []
        while let next = pending.popLast() {
            if next == target { return true }
            if visited.insert(next).inserted { pending.append(contentsOf: edges[next, default: []]) }
        }
        return false
    }
}
