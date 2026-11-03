import Testing

@testable import SQLiteMemory

@Suite("SchemaCoherence")
struct SchemaCoherenceTests {
    @Test(arguments: [
        "brain_scene_elements_not_app_scope_insert", "brain_scene_elements_not_app_scope_update",
        "brain_scene_roles_not_app_scope_insert", "brain_scene_roles_not_app_scope_update",
        "brain_scene_labels_not_app_scope_insert", "brain_scene_labels_not_app_scope_update",
        "memory_event_scenes_not_app_scope_insert", "memory_event_scenes_not_app_scope_update",
        "brain_evidence_not_app_scope_insert", "brain_evidence_not_app_scope_update",
        "brain_transitions_to_not_app_scope_insert", "brain_transitions_to_not_app_scope_update"
    ])
    func scopeRules(trigger: String) throws {
        let check = try #require(SchemaCoherence.scopeChecks[trigger])
        #expect(check("window"))
        #expect(check(nil))
        #expect(!check("app"))
    }

    @Test
    func contextualApplicationsKeepNullSafeEquality() {
        let checks = [SchemaCoherence.memoryAgentActionsAppFromEventInsert,
                      SchemaCoherence.memoryStepOperationsAppFromStepInsert,
                      SchemaCoherence.memoryStepOperationsAppFromStepUpdate,
                      SchemaCoherence.memoryStepChecksAppFromStepInsert,
                      SchemaCoherence.memoryStepChecksAppFromStepUpdate]
        for check in checks {
            #expect(check(1,1))
            #expect(check(nil,nil))
            #expect(!check(1,2))
            #expect(!check(nil,1))
        }
        for check in [SchemaCoherence.memoryOperationArgumentsAppFromOwnerInsert,
                      SchemaCoherence.memoryOperationArgumentsAppFromOwnerUpdate] {
            #expect(check(1,1,1,nil,nil))
            #expect(check(nil,nil,nil,2,nil))
            #expect(!check(1,1,2,nil,nil))
            #expect(!check(1,nil,nil,2,nil))
        }
    }

    @Test
    func actionResultChildrenKeepTheirHistoricalContracts() {
        var action = SchemaCoherence.Action(tool: "status", status: "completed", result: "status")
        #expect(SchemaCoherence.memoryAgentActionStatusInsertGuard(action))
        action.status = "planned"
        #expect(!SchemaCoherence.memoryAgentActionStatusInsertGuard(action))
        action = .init(tool: "windows", status: "completed", result: "listing")
        #expect(SchemaCoherence.memoryAgentActionListingsInsertGuard(action, "windows"))
        #expect(!SchemaCoherence.memoryAgentActionListingsInsertGuard(action, "apps"))
        action = .init(tool: "observe", status: "completed", result: "observation")
        #expect(SchemaCoherence.memoryAgentActionObservationsInsertGuard(action))
        action.tool = "status"
        #expect(!SchemaCoherence.memoryAgentActionObservationsInsertGuard(action))
        action = .init(tool: "act", status: "completed", effect: "elementsAppeared")
        #expect(SchemaCoherence.memoryAgentActionEffectLabelsInsertGuard(action))
        action.effect = "valueChanged"
        #expect(!SchemaCoherence.memoryAgentActionEffectLabelsInsertGuard(action))
        #expect(!SchemaCoherence.memoryAgentActionStatusInsertGuard(nil))
        #expect(SchemaCoherence.memoryAgentActionWindowsInsertGuard("windows"))
        #expect(!SchemaCoherence.memoryAgentActionWindowsInsertGuard("apps"))
        #expect(SchemaCoherence.memoryAgentActionApplicationsInsertGuard("windows", .init(pid: 7)))
        #expect(!SchemaCoherence.memoryAgentActionApplicationsInsertGuard("windows", .init(pid: 7, isRunning: true)))
        #expect(SchemaCoherence.memoryAgentActionApplicationsInsertGuard("apps", .init(isRunning: true)))
        #expect(!SchemaCoherence.memoryAgentActionApplicationsInsertGuard("apps", .init()))
    }

    @Test
    func verificationMembershipAndCorrelationRoles() {
        for check in [SchemaCoherence.memoryStepEventsVerificationRoleInsert, SchemaCoherence.memoryStepEventsVerificationRoleUpdate] {
            #expect(check("action",1,nil))
            #expect(check("verification",1,1))
            #expect(!check("verification",1,2))
        }
        for check in [SchemaCoherence.memoryVerificationsMatchesMembershipInsert, SchemaCoherence.memoryVerificationsMatchesMembershipUpdate] {
            #expect(check(1,[1,1]))
            #expect(check(nil,[]))
            #expect(!check(1,[1,2]))
        }
        for check in [SchemaCoherence.memoryActionCorrelationsRolesInsert, SchemaCoherence.memoryActionCorrelationsRolesUpdate] {
            #expect(check(.init(source: "watcher", kind: "input"), .init(source: "cli", kind: "action")))
            #expect(!check(.init(source: "cli", kind: "input"), .init(source: "cli", kind: "action")))
            #expect(!check(nil, .init(source: "cli", kind: "action")))
        }
    }

    @Test
    func routeAndOperationCyclesRefuseWithoutRecursingForever() {
        let routes: [Int64: [Int64]] = [2:[3],3:[4],4:[2]]
        #expect(SchemaCoherence.memoryRouteStepsNoRecursiveCalls(1,2,routes))
        #expect(!SchemaCoherence.memoryRouteStepsNoRecursiveCalls(3,2,routes))
        #expect(!SchemaCoherence.memoryRouteStepsNoRecursiveCalls(1,1,[:]))
        #expect(SchemaCoherence.memoryRouteStepsNoRecursiveCalls(1,nil,routes))
        #expect(SchemaCoherence.memoryStepOperationsNoParentCycle(1,2,[2:3]))
        #expect(!SchemaCoherence.memoryStepOperationsNoParentCycle(1,2,[2:3,3:1]))
        #expect(SchemaCoherence.memoryStepOperationsNoParentCycle(1,nil,[:]))
    }
}
