import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Route storage on both schemas", .serialized)
struct DB2CRouteTests {
    @Test(arguments: [false, true])
    func definitionsAndState(schema22: Bool) async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: schema22 ? .version22 : .historical19)
        try await store.open()
        let routes = SQLiteRouteRepository(store: store)
        let offered = ProcedureFixtures.oneGoal()
        #expect(try await routes.record(offered, state: RouteState(status: .draft)) == .committed)
        let saved = try #require(try await routes.route(offered.routeID))
        #expect(saved.definition.routeID == offered.routeID)
        #expect(saved.definition.name == offered.name)
        #expect(saved.definition.steps.first?.goalText == offered.steps.first?.goalText)
        #expect(String(describing: saved.definition.steps.first?.checks.first?.expected) == String(describing: offered.steps.first?.checks.first?.expected))
        #expect(try await routes.record(saved.definition, state: saved.state) == .alreadyApplied)
        #expect(try await routes.update(offered.routeID, from: saved.state, to: RouteState(status: .active)) == .committed)
        #expect(try await routes.route(offered.routeID)?.state.status == .active)
        #expect(try await store.read { try $0.query("PRAGMA foreign_key_check") { _ in 1 } }.isEmpty)
        await store.close()
    }
    @Test(arguments: [false, true])
    func templatesAndCompositionKeepTheirParameterOwners(schema22: Bool) async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: schema22 ? .version22 : .historical19)
        try await store.open()
        let routes = SQLiteRouteRepository(store: store)
        let parameter = RouteParameter(parameterID: "input", name: "recipient", direction: .input, valueType: .text, isRequired: true)
        let route = RouteDefinition(routeID: "callee", name: "Write", createdAtMS: ProcedureFixtures.t0, parameters: [parameter], steps: [
            ProcedureStep(stepID: "step", position: 0, goalText: "Written", checks: [ProcedureFixtures.textCheck("check")], operations: [
                StepOperation(operationID: "operation", position: 0, tool: .typeText, arguments: [
                    OperationArgument(name: "target", position: 0, value: .literal(.text("To"))),
                    OperationArgument(name: "text", position: 0, value: .template([.literal("Hello "), .parameter("input")])),
                    OperationArgument(name: "replace", position: 0, value: .literal(.boolean(true)))])])])
        #expect(try await routes.record(route, state: RouteState(status: .active)) == .committed)
        let saved = try #require(try await routes.route("callee"))
        let input = try #require(saved.definition.parameters.first)
        guard case .template(let segments)? = saved.definition.steps.first?.operations.first?.arguments.first(where: { $0.name == "text" })?.value else {
            Issue.record("expected text template"); return
        }
        guard case .parameter(let reference)? = segments.last else { Issue.record("expected parameter segment"); return }
        #expect(reference == input.parameterID)
        let own = RouteParameter(parameterID: "own", name: "name", direction: .input, valueType: .text, isRequired: true)
        let caller = RouteDefinition(routeID: "caller", name: "Call", createdAtMS: ProcedureFixtures.t0, parameters: [own], steps: [
            ProcedureStep(stepID: "call", position: 0, goalText: "Called", kind: .routeCall(calledRouteID: "callee", bindings: [
                RouteCallBinding(calledParameterID: input.parameterID, source: .parameter("own"))]))])
        #expect(try await routes.record(caller, state: RouteState(status: .active)) == .committed)
        let savedCaller = try #require(try await routes.route("caller"))
        guard case .routeCall(let callee, let bindings)? = savedCaller.definition.steps.first?.kind else {
            Issue.record("expected route call"); return
        }
        #expect(callee == "callee")
        #expect(bindings.first?.calledParameterID == input.parameterID)
        guard case .parameter(let source)? = bindings.first?.source else { Issue.record("expected source parameter"); return }
        #expect(source == savedCaller.definition.parameters.first?.parameterID)
        #expect(try await routes.record(savedCaller.definition, state: savedCaller.state) == .alreadyApplied)
        await store.close()
    }

}
