@testable import AutomationMCP
import AutomationRuntime
import Foundation
import Memory
import LocalMCP
import Testing

@MainActor
struct PlanFirstGuardTests {
    @Test func guardRefusesBeforeEffectAndAllowsReading() async throws {
        do {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session)
            _ = try await tools.call("act", .object(["target": .string("First")]))
            #expect(session.calls == ["First"])
            _ = try await tools.call("open_session", .object(["app": .string("Synthetic")]))
            do {
                _ = try await tools.call("act", .object(["target": .string("Must not run")]))
                Issue.record("Guard admitted an unplanned effect")
            } catch {
                #expect(String(describing: error).contains("Call plan first"))
            }
            #expect(!session.calls.contains("Must not run"))
            _ = try await tools.call("observe", .object([:]))
            #expect(session.calls.last == "observe")
            #expect(tools.takeInterpretationReminder() == nil)
        }
    }

    @Test func reopeningKeepsThePlanBarrier() async throws {
        let session = ToolResultSession()
        let tools = AutomationTools(session: session)
        for _ in 0..<2 {
            _ = try await tools.call("open_session", .object(["app": .string("Synthetic")]))
            await #expect(throws: AutomationFailure.self) {
                _ = try await tools.call("act", .object(["target": .string("Must not run")]))
            }
        }
        #expect(!session.calls.contains("Must not run"))
    }

}

@MainActor
struct StepTransitionTests {
    @Test func unknownStepRefusesBeforeAnEffect() async throws {
        do {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session)
            do {
                _ = try await tools.call("act", .object(["target": .string("Must not run"), "step": .string("r999")]))
                Issue.record("Unknown row reached the application")
            } catch {
                #expect(String(describing: error).contains("step must name an open row"))
                #expect(session.calls.isEmpty)
            }
        }
    }

    @Test func skippingAPendingRowRequiresAPlanRevision() async throws {
        do {
            let session = ToolResultSession()
            session.memoryDirectory = URL.temporaryDirectory.appending(path: "tu6-order-\(UUID().uuidString)")
            let secrets = ProducerSecrets()
            let scene = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: scene)
            let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
            handler.openTask = OpenTask(taskID: "task", attemptID: "attempt", revision: 1)
            handler.todo = Todo(taskID: "task", revision: 1, rows: [
                TodoRow(id: .init(rawValue: "r1"), title: "Prepare", status: .inProgress),
                TodoRow(id: .init(rawValue: "r2"), title: "Save"),
                TodoRow(id: .init(rawValue: "r3"), title: "Verify")])
            do {
                _ = try await handler.step(to: .init(rawValue: "r3"), gesture: "act")
                Issue.record("Skipped an unperformed row without revising the plan")
            } catch {
                #expect(String(describing: error).contains("plan revision with reason"))
            }
            #expect(handler.todo?.revision == 1)
            #expect(session.calls.isEmpty)
        }
    }

    @Test func configuredAllowanceStartsWhenGuardArms() async throws {
        do {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session, guardThreshold: .init(gesturesBeforePlan: 1))
            _ = try await tools.call("act", .object(["target": .string("Before opening")]))
            _ = try await tools.call("open_session", .object(["app": .string("Synthetic")]))
            _ = try await tools.call("act", .object(["target": .string("Allowed once")]))
            do {
                _ = try await tools.call("act", .object(["target": .string("Must not run")]))
                Issue.record("Guard exceeded configured allowance")
            } catch {
                #expect(String(describing: error).contains("Call plan first"))
            }
            #expect(!session.calls.contains("Must not run"))
        }
    }
}
