@testable import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Testing

@MainActor
struct OpeningFailureRenderingTests {
    @Test(arguments: [ApplicationOpeningFailure.State.unverifiedTarget, .previousRetained, .noActiveSession])
    func typedFailureUsesTheCatalogueAtTheRealToolBoundary(_ state: ApplicationOpeningFailure.State) async throws {
        let launch = ApplicationOpeningFailure.Launch(application: "Public B", seconds: 1,
            wasLaunched: true, quitRequestAccepted: true)
        let failure = ApplicationOpeningFailure(state: state, underlying: AutomationFailure("Public primary cause"),
            launch: state == .previousRetained ? launch : nil)
        let session = ToolResultSession()
        session.openingFailure = failure
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("open_session"), "arguments": .object(["app": .string("Public B")])])])
        let result = try #require(await router.handle(request))["result"]
        let text = try #require(result["content"].array?.first?["text"].string)
        #expect(result["isError"].bool == true)
        #expect(text.contains(ModelText.openingFailure(failure)))
        #expect(!text.contains("ApplicationOpeningFailure("))
        if state == .noActiveSession { #expect(text.contains("Public primary cause")) }
        #expect(session.calls == ["open"])
    }

    @Test func openingFactsAreMinimizedBeforeTheyReachTheModel() {
        let failure = ApplicationOpeningFailure(state: .previousRetained,
            launch: .init(application: "SECRET_APP", seconds: 2, wasLaunched: true, quitRequestAccepted: true),
            cleanupWarning: "SECRET_WARNING")
        let text = ModelText.openingFailure(failure, minimization: .init(secrets: ["SECRET_APP", "SECRET_WARNING"]))
        #expect(!text.contains("SECRET_APP") && !text.contains("SECRET_WARNING"))
        #expect(text.contains("was asked to quit") && text.contains("exit was not verified"))
        #expect(text.contains("previous application session is still active"))
    }
}
