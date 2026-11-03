import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence procedures")
struct SchemaCoherenceProcedureTests {
    @Test
    func candidateChecksStartedCallsMembershipOrderAndBlocks() {
        var step = SchemaCoherence.CandidateStep(tool: "act", status: "completed", attempt: 1,
                                                callAttempts: [1], occurrence: 1, callOccurrences: [1])
        #expect(SchemaCoherence.memoryCandidateStepsOperation(step))
        step.status = "planned"
        #expect(!SchemaCoherence.memoryCandidateStepsOperation(step))
        step.status = "completed"
        step.callAttempts = [2]
        #expect(!SchemaCoherence.memoryCandidateStepsOperation(step))
        step.callAttempts = [1]
        step.callOccurrences = [2]
        #expect(!SchemaCoherence.memoryCandidateStepsOperation(step))
        step.callOccurrences = [1]
        step.position = 2
        #expect(!SchemaCoherence.memoryCandidateStepsOperation(step))
        step.position = 1
        step.lastPosition = 0
        step.previousBlock = 0
        #expect(SchemaCoherence.memoryCandidateStepsOperation(step))
        step.app = 2
        step.callApp = 2
        #expect(!SchemaCoherence.memoryCandidateStepsOperation(step))
        step.block = 1
        #expect(SchemaCoherence.memoryCandidateStepsOperation(step))
        step.callApp = 3
        #expect(!SchemaCoherence.memoryCandidateStepsOperation(step))
    }

    @Test
    func interpretationAndVersionKeepCandidateAndVariantBounds() {
        #expect(SchemaCoherence.memoryProcedureInterpretationsInOrder(1,nil))
        #expect(!SchemaCoherence.memoryProcedureInterpretationsInOrder(3,1))
        #expect(SchemaCoherence.memoryProcedureVersionsInsertGuard(1,1,nil,nil,nil))
        #expect(!SchemaCoherence.memoryProcedureVersionsInsertGuard(1,2,nil,nil,nil))
        #expect(SchemaCoherence.memoryProcedureVersionsInsertGuard(1,1,2,3,3))
        #expect(!SchemaCoherence.memoryProcedureVersionsInsertGuard(1,1,2,4,3))
    }

    @Test
    func partsKeepVersionContainmentAndStepPosition() {
        let child = SchemaCoherence.Part(route: 1, kind: "step", first: 2, last: 2)
        let parent = SchemaCoherence.Part(route: 1, kind: "procedure", first: 0, last: 3)
        #expect(SchemaCoherence.memoryProcedurePartsContainment(child, parent, 9))
        let otherRoute = SchemaCoherence.Part(route: 2, kind: "procedure", first: 0, last: 3)
        let sameLevel = SchemaCoherence.Part(route: 1, kind: "step", first: 2, last: 2)
        let acceptsOtherRoute = SchemaCoherence.memoryProcedurePartsContainment(child, otherRoute, 9)
        let acceptsSameLevel = SchemaCoherence.memoryProcedurePartsContainment(child, sameLevel, 9)
        #expect(!acceptsOtherRoute)
        #expect(!acceptsSameLevel)
        #expect(SchemaCoherence.memoryProcedurePartsStepPosition("step",2,2))
        #expect(!SchemaCoherence.memoryProcedurePartsStepPosition("step",2,1))
    }

    @Test
    func argumentFormsSecretBindingsAndQualificationEvidence() {
        #expect(SchemaCoherence.memoryOperationArgumentSegmentsAlone(false))
        #expect(!SchemaCoherence.memoryOperationArgumentSegmentsAlone(true))
        #expect(SchemaCoherence.memoryOperationArgumentsNotTemplated(nil,true))
        #expect(!SchemaCoherence.memoryOperationArgumentsNotTemplated(1,true))
        #expect(SchemaCoherence.memoryParameterBindingsSecret("withheld","secret"))
        #expect(!SchemaCoherence.memoryParameterBindingsSecret("text","secret"))
        #expect(SchemaCoherence.memoryPartQualificationsInOrder(2,1))
        #expect(!SchemaCoherence.memoryPartQualificationsInOrder(3,1))
        #expect(SchemaCoherence.memoryPartQualificationReasonsRefusedOnly("refused"))
        #expect(!SchemaCoherence.memoryPartQualificationReasonsRefusedOnly("admitted"))
        #expect(SchemaCoherence.memoryPartQualificationEvidenceOwnCall(1,1))
        #expect(!SchemaCoherence.memoryPartQualificationEvidenceOwnCall(1,2))
        #expect(SchemaCoherence.memoryPartStatesInOrder(2,1,"usable"))
        #expect(!SchemaCoherence.memoryPartStatesInOrder(2,1,"retired"))
        #expect(SchemaCoherence.memoryQualificationPoliciesForward("v1","v1",1,2))
        #expect(!SchemaCoherence.memoryQualificationPoliciesForward("v1","v2",1,2))
        #expect(!SchemaCoherence.memoryQualificationPoliciesForward("v1","v1",2,1))
    }

    @Test
    func relationProofsAndPrefixesKeepTheirOwners() {
        #expect(SchemaCoherence.brainRelationsNotAppScope("window",nil))
        #expect(!SchemaCoherence.brainRelationsNotAppScope("window","app"))
        #expect(SchemaCoherence.brainRelationProofsOwnCall(1,1,2,2))
        #expect(!SchemaCoherence.brainRelationProofsOwnCall(1,2,2,2))
        #expect(SchemaCoherence.brainSceneShapesNotAppScope("window"))
        #expect(!SchemaCoherence.brainSceneShapesNotAppScope("app"))
        #expect(SchemaCoherence.brainRelationEvaluationsInOrder(2,1,3,3))
        #expect(!SchemaCoherence.brainRelationEvaluationsInOrder(2,1,3,4))
        #expect(SchemaCoherence.brainRelationEvidenceOwnCall(1,1,2,2,"supports","supported"))
        #expect(!SchemaCoherence.brainRelationEvidenceOwnCall(1,1,2,2,"supports","contradicted"))
        #expect(SchemaCoherence.brainAnchorLabelKeysOwnApp(1,1))
        #expect(!SchemaCoherence.brainAnchorLabelKeysOwnApp(1,2))
        for check in [SchemaCoherence.memoryVariantPrefixesOfVariants, SchemaCoherence.memoryVariantPrefixChecksOfVariants] {
            #expect(check(1,3,3))
            #expect(!check(nil,nil,0))
            #expect(!check(1,3,4))
        }
    }
}
