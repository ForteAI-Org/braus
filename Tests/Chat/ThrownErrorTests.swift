import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Testing

@MainActor
struct ThrownErrorTests {
    @Test func actionWithoutSessionIsNotSent() async throws {
        let session = ToolResultSession()
        session.id = nil
        try await session.withPlannedTools { tools in
            do {
                _ = try await tools.call("act", .object(["target": .string("Control"), "step": .string("r1")]))
                Issue.record("A gesture without a current session was accepted")
            } catch let error as AutomationFailure {
                #expect(error.description.lowercased().contains("session"))
            }
            #expect(session.calls.isEmpty)
        }
    }

    @Test func failingActionIsUncertainAndCannotBeRepeatedBlindly() async throws {
        let session = ToolResultSession()
        session.throwOnTarget = "Control"
        try await session.withPlannedTools { tools in
            let result = try await tools.call("act", .object(["target": .string("Control"), "step": .string("r1")]))
            #expect(result["isError"].bool == true)
            #expect(result["content"].array?.first?["text"].string?
                .contains("uncertain · unknown(not_readable) · do_not_repeat") == true)
        }
    }

    @Test func invalidArgumentsAreRefusedBeforeDispatch() async throws {
        let session = ToolResultSession()
        try await session.withPlannedTools { tools in
            do {
                _ = try await tools.call("act", .object(["target": .string("Control"),
                    "step": .string("r1"), "extra": .bool(true)]))
                Issue.record("An unknown argument was accepted")
            } catch let error as AutomationFailure {
                #expect(error.cause == "invalid_arguments")
            }
            #expect(session.calls.isEmpty)
        }
    }

    @Test func cancellationStillThrows() async throws {
        let session = ToolResultSession()
        session.actionError = CancellationError()
        try await session.withPlannedTools { tools in
            do {
                _ = try await tools.call("act", .object(["target": .string("Control"), "step": .string("r1")]))
                Issue.record("Cancellation was returned instead of thrown")
            } catch is CancellationError {}
        }
    }

    @Test func readOnlyErrorsStillThrow() async throws {
        let session = ToolResultSession()
        session.observationFailure = AutomationFailure("Synthetic read failure.")
        let tools = AutomationTools(session: session)
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("observe", .object([:]))
        }
        #expect(session.calls == ["observe"])
    }
}
