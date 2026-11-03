import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence Recall and fields")
struct SchemaCoherenceRecallTests {
    @Test
    func generationLifecycle() {
        let building = SchemaCoherence.Generation(id: 1, format: "v1", space: nil, started: 0)
        #expect(SchemaCoherence.memoryRecallGenerationsBornBuilding(building))
        var ready = building
        ready.status = "ready"
        ready.enumerated = true
        #expect(!SchemaCoherence.memoryRecallGenerationsBornBuilding(ready))
        #expect(SchemaCoherence.memoryRecallGenerationsTransitions(building, ready))
        #expect(!SchemaCoherence.memoryRecallGenerationsTransitions(ready, building))
        var retired = ready
        retired.status = "retired"
        #expect(SchemaCoherence.memoryRecallGenerationsTransitions(ready, retired))
        var changed = retired
        changed.revision = 1
        #expect(!SchemaCoherence.memoryRecallGenerationsTransitions(retired, changed))
        changed = ready
        changed.format = "v2"
        #expect(!SchemaCoherence.memoryRecallGenerationsTransitions(building, changed))
    }

    @Test
    func derivedLifecycleAllowsDeclaredRebuilds() {
        let checks = [SchemaCoherence.memoryRecallGenerationsKept,
                      SchemaCoherence.memoryRecallDocumentsImmutable,
                      SchemaCoherence.memoryRecallVectorsImmutable,
                      SchemaCoherence.memoryRecallEntriesImmutable,
                      SchemaCoherence.memoryRecallWorkKept]
        for check in checks {
            #expect(check(true))
            #expect(!check(false))
        }
        #expect(SchemaCoherence.memoryRecallVectorsShape(12, 3, "float32"))
        #expect(!SchemaCoherence.memoryRecallVectorsShape(8, 3, "float32"))
        #expect(!SchemaCoherence.memoryRecallVectorsShape(3, 3, "int8"))
        #expect(!SchemaCoherence.memoryRecallVectorsShape(12, 3, "unknown"))
        #expect(SchemaCoherence.memoryRecallEntriesValid("ready", 1, 1, "step", "step", "v1", "v1"))
        #expect(!SchemaCoherence.memoryRecallEntriesValid("failed", 1, 1, "step", "step", "v1", "v1"))
        #expect(!SchemaCoherence.memoryRecallEntriesValid("ready", 1, 2, "step", "step", "v1", "v1"))
        #expect(!SchemaCoherence.memoryRecallEntriesValid("ready", 1, 1, "step", "procedure", "v1", "v1"))
        #expect(!SchemaCoherence.memoryRecallEntriesValid("ready", 1, 1, "step", "step", "v1", "v2"))
        let work = SchemaCoherence.RecallWork(id: 1, route: nil, reason: "rebuild", enqueued: 0, done: nil, attempts: 0)
        var next = work
        next.done = 1
        next.attempts = 1
        #expect(SchemaCoherence.memoryRecallWorkProgress(work, next))
        #expect(!SchemaCoherence.memoryRecallWorkProgress(next, work))
        next.reason = "policy"
        #expect(!SchemaCoherence.memoryRecallWorkProgress(work, next))
    }

    @Test
    func selectionLinksReportsAndSourceNames() {
        let part = SchemaCoherence.Part(route: 1, kind: "step", first: 0, last: 2)
        #expect(SchemaCoherence.memoryRecallSelectionsValid(1, 0, 2, 2, 1, part, "selected", "complete"))
        #expect(!SchemaCoherence.memoryRecallSelectionsValid(1, 0, 3, 2, nil, nil, "selected", "complete"))
        #expect(!SchemaCoherence.memoryRecallSelectionsValid(2, 0, 2, 2, 1, part, "selected", "complete"))
        #expect(!SchemaCoherence.memoryRecallSelectionsValid(1, 0, 2, 2, nil, nil, "selected", "absent"))
        #expect(SchemaCoherence.memoryRecallSelectionsValid(1, 0, 2, 2, nil, nil, "excluded", "absent"))
        #expect(!SchemaCoherence.memoryRecallSelectionsValid(1, 0, 2, 2, nil, nil, "excluded", "unknown"))
        for check in [SchemaCoherence.memoryRecallLinksValid, SchemaCoherence.memoryRecallChoiceLinksValid] {
            #expect(check(true, nil, false))
            #expect(check(true, 2, true))
            #expect(!check(false, nil, false))
            #expect(!check(true, 2, false))
        }
        #expect(SchemaCoherence.memoryRecallReportsInOrder(2, 1))
        #expect(!SchemaCoherence.memoryRecallReportsInOrder(3, 1))
        #expect(SchemaCoherence.memoryRecallProposalSourcesNamed("s1", 1, [("s1", 1), ("s2", 2)]))
        #expect(!SchemaCoherence.memoryRecallProposalSourcesNamed("s1", 2, [("s1", 1)]))
        #expect(!SchemaCoherence.memoryRecallProposalSourcesNamed("s2", 1, [("s1", 1)]))
    }

    @Test
    func choicesAndRequirements() {
        let owner = SchemaCoherence.RecallOwner(task: 1, attempt: 2, revision: 3, source: "cli", stream: "s")
        #expect(SchemaCoherence.memoryRecallChoicesValid(owner, owner))
        #expect(!SchemaCoherence.memoryRecallChoicesValid(owner, nil))
        #expect(SchemaCoherence.memoryRecallChoiceNeedsValid("ambiguous", 0, 2, "ambiguous"))
        #expect(!SchemaCoherence.memoryRecallChoiceNeedsValid("ambiguous", 1, 2, "ambiguous"))
        #expect(!SchemaCoherence.memoryRecallChoiceNeedsValid("ambiguous", 0, 1, "ambiguous"))
        #expect(!SchemaCoherence.memoryRecallChoiceNeedsValid("ambiguous", 0, 2, "partial"))
        #expect(SchemaCoherence.memoryRecallLinksNotOfChoices(false))
        #expect(!SchemaCoherence.memoryRecallLinksNotOfChoices(true))
        var requirement = SchemaCoherence.RecallRequirement(kind: "input_produced", step: 1, inSelection: false,
                                                           inEarlierSelection: true)
        #expect(SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.inEarlierSelection = false
        #expect(!SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.kind = "prepared_before"
        requirement.isVersionStep = true
        requirement.beforeSelection = true
        #expect(SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.beforeSelection = false
        #expect(!SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.kind = "prerequisite_out_of_catalogue"
        #expect(SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.kind = "certain_conflict"
        requirement.inSelection = true
        #expect(!SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.selectionRole = "excluded"
        #expect(SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.hasParameter = true
        #expect(!SchemaCoherence.memoryRecallRequirementsValid(requirement))
        requirement.parameterInVersion = true
        #expect(SchemaCoherence.memoryRecallRequirementsValid(requirement))
    }

    @Test
    func referencesFormsAndReconciliation() {
        #expect(SchemaCoherence.memoryCallArgumentFieldsReference("result_reference", true))
        #expect(!SchemaCoherence.memoryCallArgumentFieldsReference("result_reference", false))
        #expect(SchemaCoherence.memoryCallArgumentFieldsReference("text", false))
        #expect(SchemaCoherence.memoryOperationArgumentFieldsOneForm(false, false, "step_result", 1, 2))
        #expect(!SchemaCoherence.memoryOperationArgumentFieldsOneForm(true, false, "text", nil, nil))
        #expect(!SchemaCoherence.memoryOperationArgumentFieldsOneForm(false, true, "text", nil, nil))
        #expect(!SchemaCoherence.memoryOperationArgumentFieldsOneForm(false, false, "step_result", 2, 2))
        #expect(SchemaCoherence.memoryCallReconciliationsOrder(2, 1, nil, nil, nil, nil))
        #expect(SchemaCoherence.memoryCallReconciliationsOrder(2, 1, 4, "completed", 10, 10))
        #expect(!SchemaCoherence.memoryCallReconciliationsOrder(3, 1, nil, nil, nil, nil))
        #expect(!SchemaCoherence.memoryCallReconciliationsOrder(2, 1, 4, "failed", 10, 10))
        #expect(!SchemaCoherence.memoryCallReconciliationsOrder(2, 1, 4, "completed", 9, 10))
    }
}
