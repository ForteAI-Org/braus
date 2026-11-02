import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Switches
import Testing

@MainActor
struct ThrownErrorTests {
    @Test func actionWithoutSessionIsNotSent() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            session.id = nil
            let tools = AutomationTools(session: session)
            let result = try await tools.call("act", .object(["session": .string("missing"), "target": .string("Control")]))
            #expect(result["isError"].bool == true)
            #expect(result["content"].array?.first?["text"].string?
                .hasPrefix("not_sent · not_applicable · do_not_repeat") == true)
            #expect(result["content"].array?.first?["text"].string?.contains("session") == true)
        }
    }

    @Test func failingActionIsUncertain() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            session.throwOnTarget = "Control"
            let tools = AutomationTools(session: session)
            let result = try await tools.call("act", .object([
                "session": .string(try #require(session.id).uuidString), "target": .string("Control")
            ]))
            #expect(result["isError"].bool == true)
            #expect(result["content"].array?.first?["text"].string?
                .hasPrefix("uncertain · unknown(not_readable) · observe") == true)
        }
    }

    @Test func invalidArgumentsHaveNotActed() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            let tools = AutomationTools(session: session)
            let result = try await tools.call("act", .object([
                "session": .string(try #require(session.id).uuidString), "target": .string("Control"),
                "extra": .bool(true)
            ]))
            #expect(result["content"].array?.first?["text"].string?
                .hasPrefix("not_sent · not_applicable · retry") == true)
            #expect(result["content"].array?.first?["text"].string?.contains("arguments") == true)
            #expect(session.calls.isEmpty)
        }
    }

    @Test func cancellationStillThrows() async throws {
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            session.actionError = CancellationError()
            let tools = AutomationTools(session: session)
            do {
                _ = try await tools.call("act", .object([
                    "session": .string(try #require(session.id).uuidString), "target": .string("Control")
                ]))
                Issue.record("Cancellation was returned instead of thrown")
            } catch is CancellationError {}
        }
    }

    @Test func readOnlyAndV1ErrorsStillThrow() async throws {
        for arm in ["v1", "v2"] {
            try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": arm])) {
                let session = ToolResultSession()
                session.observationFailure = AutomationFailure("Synthetic read failure.")
                let tools = AutomationTools(session: session)
                do {
                    _ = try await tools.call("observe", .object(["session": .string(try #require(session.id).uuidString)]))
                    Issue.record("Read failure was returned instead of thrown")
                } catch is AutomationFailure {}
                if arm == "v1" {
                    session.throwOnTarget = "Control"
                    do {
                        _ = try await tools.call("act", .object([
                            "session": .string(try #require(session.id).uuidString), "target": .string("Control")
                        ]))
                        Issue.record("The default arm swallowed an action error")
                    } catch is AutomationFailure {}
                }
            }
        }
    }
}
