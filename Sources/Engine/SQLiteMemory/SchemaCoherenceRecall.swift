extension SchemaCoherence {
    struct Generation {
        var id: Int64
        var format: String
        var space: Int64?
        var started: Int64
        var status = "building"
        var enumerated = false
        var revision: Int64 = 0
        var cursor: Int64? = nil
    }

    /// Replaces memory_recall_generations_born_building.
    static func memoryRecallGenerationsBornBuilding(_ row: Generation) -> Bool {
        row.status == "building" && !row.enumerated && row.revision == 0
    }

    /// Replaces memory_recall_generations_transitions.
    static func memoryRecallGenerationsTransitions(_ old: Generation, _ row: Generation) -> Bool {
        guard old.id == row.id, old.format.utf8.elementsEqual(row.format.utf8), old.space == row.space,
              old.started == row.started, row.revision >= old.revision, !old.enumerated || row.enumerated else { return false }
        if ["retired", "failed"].contains(old.status) {
            return row.status == old.status && row.revision == old.revision
                && row.cursor == old.cursor && row.enumerated == old.enumerated
        }
        return row.status == old.status
            || (old.status == "building" && ["ready", "failed", "retired"].contains(row.status))
            || (old.status == "ready" && row.status == "retired")
    }

    /// Replaces memory_recall_generations_kept under the declared derived-index lifecycle exception.
    static func memoryRecallGenerationsKept(_ rebuilding: Bool) -> Bool { rebuilding }
    /// Replaces memory_recall_documents_immutable under the declared derived-index lifecycle exception.
    static func memoryRecallDocumentsImmutable(_ rebuilding: Bool) -> Bool { rebuilding }
    /// Replaces memory_recall_vectors_immutable under the declared derived-index lifecycle exception.
    static func memoryRecallVectorsImmutable(_ rebuilding: Bool) -> Bool { rebuilding }
    /// Replaces memory_recall_entries_immutable under the declared derived-index lifecycle exception.
    static func memoryRecallEntriesImmutable(_ rebuilding: Bool) -> Bool { rebuilding }
    /// Replaces memory_recall_work_kept under the declared derived-index lifecycle exception.
    static func memoryRecallWorkKept(_ rebuilding: Bool) -> Bool { rebuilding }

    /// Replaces memory_recall_vectors_shape. Missing spaces remain the FK's responsibility.
    static func memoryRecallVectorsShape(_ bytes: Int64, _ dimensions: Int64?, _ precision: String?) -> Bool {
        guard let dimensions else { return true }
        let (expected, overflow) = dimensions.multipliedReportingOverflow(by: 4)
        return precision == "float32" && !overflow && bytes == expected
    }

    /// Replaces memory_recall_entries_valid. Historical entries can remain in final generations at rest.
    static func memoryRecallEntriesValid(
        _ status: String?, _ route: Int64, _ partRoute: Int64?, _ kind: String, _ partKind: String?,
        _ format: String?, _ generationFormat: String?
    ) -> Bool {
        (status == nil || ["building", "ready"].contains(status ?? "")) && route == partRoute && kind == partKind
            && format.map { Array($0.utf8) } == generationFormat.map { Array($0.utf8) }
    }

    struct RecallWork {
        var id: Int64
        var route: Int64?
        var reason: String
        var enqueued: Int64
        var done: Int64?
        var attempts: Int64
    }

    /// Replaces memory_recall_work_progress.
    static func memoryRecallWorkProgress(_ old: RecallWork, _ row: RecallWork) -> Bool {
        old.id == row.id && old.route == row.route && old.reason.utf8.elementsEqual(row.reason.utf8)
            && old.enqueued == row.enqueued && (old.done == nil || old.done == row.done) && row.attempts >= old.attempts
    }

    /// Replaces memory_recall_selections_valid.
    static func memoryRecallSelectionsValid(
        _ route: Int64, _ first: Int64, _ last: Int64, _ maximum: Int64?, _ wholeID: Int64?, _ whole: Part?,
        _ role: String, _ coverage: String?
    ) -> Bool {
        if let maximum, last > maximum { return false }
        if wholeID != nil {
            guard let whole, whole.route == route, whole.first == first, whole.last == last else { return false }
        }
        return role == "excluded" ? coverage != "unknown" : !["absent", "unknown"].contains(coverage ?? "")
    }

    /// Replaces memory_recall_links_valid.
    static func memoryRecallLinksValid(_ ownCall: Bool, _ step: Int64?, _ inSelection: Bool) -> Bool {
        ownCall && (step == nil || inSelection)
    }

    /// Replaces memory_recall_reports_in_order.
    static func memoryRecallReportsInOrder(_ sequence: Int64, _ previous: Int64?) -> Bool { isNext(sequence, after: previous) }

    /// Replaces memory_recall_proposal_sources_named.
    static func memoryRecallProposalSourcesNamed(_ key: String, _ route: Int64, _ sources: [(String, Int64)]) -> Bool {
        sources.allSatisfy { key.utf8.elementsEqual($0.0.utf8) == (route == $0.1) }
    }

    struct RecallOwner: Equatable {
        let task: Int64
        let attempt: Int64
        let revision: Int64
        let source: String
        let stream: String
    }

    /// Replaces memory_recall_choices_valid.
    static func memoryRecallChoicesValid(_ query: RecallOwner?, _ proposal: RecallOwner?) -> Bool {
        guard let query, let proposal else { return false }
        return query.task == proposal.task && query.attempt == proposal.attempt && query.revision == proposal.revision
            && query.source.utf8.elementsEqual(proposal.source.utf8) && query.stream.utf8.elementsEqual(proposal.stream.utf8)
    }

    /// Replaces memory_recall_choice_needs_valid.
    static func memoryRecallChoiceNeedsValid(_ declared: String, _ selected: Int64, _ alternatives: Int64, _ coverage: String?) -> Bool {
        declared != "ambiguous" || (selected == 0 && alternatives >= 2 && (coverage == nil || coverage == "ambiguous"))
    }

    /// Replaces memory_recall_choice_links_valid.
    static func memoryRecallChoiceLinksValid(_ ownCall: Bool, _ step: Int64?, _ inSelection: Bool) -> Bool {
        memoryRecallLinksValid(ownCall, step, inSelection)
    }

    /// Replaces memory_recall_links_not_of_choices.
    static func memoryRecallLinksNotOfChoices(_ hasChoice: Bool) -> Bool { !hasChoice }

    struct RecallRequirement {
        var kind: String
        var step: Int64?
        var inSelection = false
        var inEarlierSelection = false
        var isVersionStep = false
        var beforeSelection = false
        var selectionRole: String? = "selected"
        var hasParameter = false
        var parameterInVersion = false
    }

    /// Replaces memory_recall_requirements_valid.
    static func memoryRecallRequirementsValid(_ row: RecallRequirement) -> Bool {
        let outside = ["prerequisite_out_of_catalogue", "prepared_before", "output_ready"].contains(row.kind)
        if row.step != nil && !outside && !row.inSelection
            && !(row.kind == "input_produced" && row.inEarlierSelection) { return false }
        if outside && !(row.isVersionStep && (row.kind == "prerequisite_out_of_catalogue" || row.beforeSelection)) { return false }
        if let role = row.selectionRole,
           ["certain_conflict", "constraint_excluded"].contains(row.kind) != (role == "excluded") { return false }
        return !row.hasParameter || row.parameterInVersion
    }

    /// Replaces memory_call_argument_fields_reference.
    static func memoryCallArgumentFieldsReference(_ kind: String, _ earlierKeptResultInAttempt: Bool) -> Bool {
        kind != "result_reference" || earlierKeptResultInAttempt
    }

    /// Replaces memory_operation_argument_fields_one_form.
    static func memoryOperationArgumentFieldsOneForm(
        _ hasScalar: Bool, _ hasTemplate: Bool, _ kind: String, _ sourcePosition: Int64?, _ ownPosition: Int64?
    ) -> Bool {
        guard !hasScalar, !hasTemplate else { return false }
        guard kind == "step_result", let sourcePosition, let ownPosition else { return true }
        return sourcePosition < ownPosition
    }

    /// Replaces memory_call_reconciliations_order.
    static func memoryCallReconciliationsOrder(
        _ sequence: Int64, _ previous: Int64?, _ evidence: Int64?, _ status: String?, _ evidenceTime: Int64?, _ callTime: Int64?
    ) -> Bool {
        guard isNext(sequence, after: previous) else { return false }
        guard evidence != nil else { return true }
        guard status == "completed", let evidenceTime, let callTime else { return false }
        return evidenceTime >= callTime
    }
}
