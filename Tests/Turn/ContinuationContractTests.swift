@testable import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import Memory
import ModelTransports
import PerceptionCore
import Testing
@testable import Turn

@MainActor
struct ContinuationContractTests {
    @Test func openPlanSurvivesASecondTurnWithoutToolHistory() async throws {
        let root = try testTurnRoot()
        let session = ContinuationFixture(directory: root.appending(path: "archive"))
        let tools = AutomationTools(session: session)
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false,
            closesSessionOnEnd: false), host: host)
        let plan = Data(#"{"request":"Prepare public report","inputs":[{"name":"topic","value":"PUBLIC_TOPIC"}],"rows":[{"title":"Prepare","expect":{"none":"Await person"}},{"title":"Verify"}]}"#.utf8)
        let first = TurnTestTransport([[
            .toolCall(.init(id: "plan", name: "plan", arguments: plan))], [.delta("Please clarify the format.")]])
        _ = try await runner.run(.init(prompt: "Prepare the report", route: .modelLoop(transport: first, contextWindow: nil))) { _ in }
        let task = try #require(tools.openTask)
        let second = TurnTestTransport([[.delta("I can continue.")]])
        _ = try await runner.run(.init(prompt: "Use plain text", route: .modelLoop(transport: second, contextWindow: nil))) { _ in }
        let sent = try #require(second.messages.first).map(\.text).joined(separator: "\n")
        #expect(sent.contains("r1") && sent.contains("r2"))
        #expect(sent.contains("PUBLIC_TOPIC"))
        #expect(sent.contains("Await person"))
        #expect(tools.openTask == task)
        try await runner.close()
        await MemoryService.shared(for: session.memoryDirectory!).close()
        MemoryService.forget(session.memoryDirectory!)
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ContinuationFixture: AutomationSessionOperating {
    let id: UUID? = nil
    let memoryDirectory: URL?
    init(directory: URL) { memoryDirectory = directory }
    func open(application: String, window: String?) async throws -> SceneSnapshot { throw AutomationFailure("Unexpected open") }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("Unexpected observe") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome { throw AutomationFailure("Unexpected action") }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected selection") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("Unexpected input") }
    func menu(path: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected menu") }
    func close() async {}
}
