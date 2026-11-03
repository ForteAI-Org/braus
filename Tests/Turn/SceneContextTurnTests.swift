import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import ModelTransports
import PerceptionCore
import Testing
@testable import Turn

@MainActor
struct NoResetAtTurnStartTests {
    @Test func commandRouteKeepsSceneWhenNextTurnIsAdmitted() async throws {
        let session = SceneTurnSession()
        let tools = AutomationTools(session: session)
        let host = TestTurnHost()
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: root.appending(path: "missing"), allowsSuspension: false,
            closesSessionOnEnd: false), host: host)
        for index in 0..<2 {
            // Admission and context handling precede the missing bridge check, without starting a local endpoint.
            await #expect(throws: AutomationFailure.self) {
                try await runner.run(.init(prompt: "Read", route: .commandLine(provider: .codex,
                    executable: URL(filePath: "/bin/false"), model: nil, effort: nil,
                    environment: [:], allowsWebSearch: false), sessionID: "synthetic")) { _ in }
            }
            session.scene.elements[0].value = String(index)
            let answer = try await tools.call("observe", .object(["session": .string(session.id!.uuidString)]))
            let payload = try scenePayload(answer)
            if index == 0 { #expect(payload["scene"].string != nil) }
            else { #expect(payload["changes"].string != nil) }
        }
        #expect(runner.contextState.resets == 0)
        try await runner.close()
    }
}

@MainActor
struct LoopRouteHoldsNoSceneTests {
    @Test func historyWindowLosingAnchorResetsAsCompaction() async throws {
        let session = SceneTurnSession()
        let tools = AutomationTools(session: session)
        let host = TestTurnHost()
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false,
            closesSessionOnEnd: false), host: host)
        for _ in 0..<2 {
            let transport = TurnTestTransport([[.completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]])
            _ = try await runner.run(.init(prompt: "Read", route: .modelLoop(transport: transport,
                contextWindow: nil))) { _ in }
            let answer = try await tools.call("observe", .object(["session": .string(session.id!.uuidString)]))
            #expect(try scenePayload(answer)["scene"].string != nil)
            #expect(runner.contextState.lastReset == .compaction)
        }
        #expect(runner.contextState.resets == 2)
        try await runner.close()
    }
}

@MainActor
struct PersonHadAppTests {
    @Test func suspensionAndEndRequireAReasonedWholeReading() async throws {
        let session = SceneTurnSession()
        let tools = AutomationTools(session: session)
        let host = TestTurnHost()
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: true,
            closesSessionOnEnd: false), host: host)
        let args = JSONValue.object(["session": .string(session.id!.uuidString)])
        _ = try await tools.call("observe", args)
        let token = try runner.suspend()
        try runner.end(token)
        let whole = try await tools.call("observe", args)
        #expect(try scenePayload(whole)["scene"].string?.hasPrefix(
            "Whole scene: the person used the application since your last reading.\n") == true)
        session.scene.elements[0].value = "changed"
        let next = try await tools.call("observe", args)
        #expect(try scenePayload(next)["changes"].string != nil)
        #expect(runner.contextState.lastReset == .personHadApp)
        try await runner.close()
    }
}

@MainActor
private final class SceneTurnSession: AutomationSessionOperating {
    var id: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    var observedWindowNumber: Int? { 1 }
    var scene = SceneSnapshot(bundleID: "test.scene", appName: "Example", windowTitle: "Document",
        viewportPixelSize: .init(width: 800, height: 600), elements: (0..<25).map {
            SceneElement(id: "row\($0)", kind: .control, label: "Setting \($0)",
                bounds: .init(x: 0, y: Double($0) / 30, width: 0.5, height: 0.02))
        })
    func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
    func observe() async throws -> SceneSnapshot { scene }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("Unexpected action")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected selection") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("Unexpected input")
    }
    func menu(path: String) async throws -> ActOutcome { throw AutomationFailure("Unexpected menu") }
    func close() async { id = nil }
}


private func scenePayload(_ answer: JSONValue) throws -> JSONValue {
    if answer["structuredContent"].object != nil { return answer["structuredContent"] }
    let text = try #require(answer["content"].array?.first?["text"].string)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}
