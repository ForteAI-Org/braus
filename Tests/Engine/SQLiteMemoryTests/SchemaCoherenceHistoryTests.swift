import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence history")
struct SchemaCoherenceHistoryTests {
    @Test
    func captureAssociationsNeedTheirSampleAndConfirmedQuality() {
        for check in [SchemaCoherence.memoryEventScenesRequireCaptureInsert, SchemaCoherence.memoryEventScenesRequireCaptureUpdate] {
            #expect(check("confirmed", "complete"))
            #expect(check("candidate", "partial"))
            #expect(!check("confirmed", "partial"))
            #expect(!check("candidate", nil))
        }
        let key = SchemaCoherence.CaptureKey(event: 1, phase: "current", ordinal: 0)
        let other = SchemaCoherence.CaptureKey(event: 2, phase: "current", ordinal: 0)
        #expect(SchemaCoherence.memoryEventObservationsCaptureIdentityGuard("capture", key, "capture", key, true))
        #expect(!SchemaCoherence.memoryEventObservationsCaptureIdentityGuard("capture", key, "capture", other, true))
        #expect(SchemaCoherence.memoryEventObservationsCaptureIdentityGuard("capture", key, "element", other, false))
        #expect(SchemaCoherence.memoryEventObservationsCaptureStatusGuard("capture", "complete", true))
        #expect(!SchemaCoherence.memoryEventObservationsCaptureStatusGuard("capture", "partial", true))
        #expect(SchemaCoherence.memoryEventObservationsCaptureStatusGuard("element", "observed", true))
        #expect(!SchemaCoherence.memoryEventObservationsCaptureDeleteGuard("capture", true))
        #expect(SchemaCoherence.memoryEventObservationsCaptureDeleteGuard("capture", false))
    }

    @Test
    func historicalProjectionInputsAreSealedAfterApplication() {
        #expect(SchemaCoherence.brainApplicationsInsertGuard(true, "record", "action", 3, 4, 3))
        #expect(!SchemaCoherence.brainApplicationsInsertGuard(false, "record", "action", 3, nil, nil))
        #expect(!SchemaCoherence.brainApplicationsInsertGuard(true, "record", "observation", 3, nil, nil))
        #expect(!SchemaCoherence.brainApplicationsInsertGuard(true, "record", "action", 3, 4, 5))
        #expect(SchemaCoherence.memoryOperationArgumentsApplicationSealed(1, false))
        #expect(!SchemaCoherence.memoryOperationArgumentsApplicationSealed(1, true))
        #expect(SchemaCoherence.memoryOperationArgumentsApplicationImmutable(nil,nil))
        #expect(!SchemaCoherence.memoryOperationArgumentsApplicationImmutable(1,nil))
        #expect(SchemaCoherence.memoryOperationArgumentsApplicationKept(nil))
        #expect(!SchemaCoherence.memoryOperationArgumentsApplicationKept(1))
    }

    @Test
    func taskHistoryIsConsecutiveAndResumeKeepsTheTask() {
        #expect(SchemaCoherence.memoryTaskRevisionsInOrder(1,nil))
        #expect(SchemaCoherence.memoryTaskRevisionsInOrder(3,2))
        #expect(!SchemaCoherence.memoryTaskRevisionsInOrder(3,1))
        #expect(!SchemaCoherence.memoryTaskRevisionsInOrder(1,Int64.max))
        #expect(SchemaCoherence.memoryTaskAttemptsResumeSameTask(1,nil,nil))
        #expect(SchemaCoherence.memoryTaskAttemptsResumeSameTask(1,3,1))
        #expect(!SchemaCoherence.memoryTaskAttemptsResumeSameTask(1,3,2))
        #expect(SchemaCoherence.memoryTaskCheckpointsInOrder(2,1,false))
        #expect(!SchemaCoherence.memoryTaskCheckpointsInOrder(2,1,true))
        #expect(!SchemaCoherence.memoryTaskCheckpointsInOrder(3,1,false))
    }

    @Test
    func callChildrenRequireConclusionAndCallVerificationScope() {
        let checks = [SchemaCoherence.memoryCallEffectsConcludedCall, SchemaCoherence.memoryCallRoutesConcludedCall,
                      SchemaCoherence.memoryCallAdapterDispatchesConcludedCall, SchemaCoherence.memoryCallRungsConcludedCall,
                      SchemaCoherence.memoryCallRouteAdviceConcludedCall, SchemaCoherence.memoryCallRecordingGapsConcludedCall,
                      SchemaCoherence.memoryCallArgumentFieldsConcludedCall, SchemaCoherence.memoryCallResultFieldsConcludedCall,
                      SchemaCoherence.memoryCallDataContextsConcludedCall]
        for check in checks {
            #expect(check("completed"))
            #expect(check("interrupted"))
            #expect(!check("started"))
            #expect(!check("planned"))
            #expect(check(nil))
        }
        #expect(SchemaCoherence.memoryOperationVerificationsCallScope("call"))
        #expect(!SchemaCoherence.memoryOperationVerificationsCallScope("task"))
        #expect(!SchemaCoherence.memoryOperationVerificationsCallScope(nil))
    }
}
