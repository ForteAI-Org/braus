import AutomationMCP
import AutomationRuntime
import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import Synchronization
import Testing
import Turn

@MainActor
final class TestTurnHost: TurnHosting {
    var began = 0
    var stopping = 0
    var scope: (() async throws -> Void)?
    func admission(of tool: String, _ arguments: JSONValue) -> String? { nil }
    func withinCallScope<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await scope?()
        return try await body()
    }
    func turnBegan() { began += 1 }
    func turnStopping() { stopping += 1 }
    func seatFacts() -> SeatFacts? { SeatFacts() }
}

final class TurnTestTransport: ModelTransport {
    private struct State {
        var rounds: [[TurnEvent]]
        var messages: [[TurnMessage]] = []
    }
    private let state: Mutex<State>
    private let failure: (any Error)?
    init(_ rounds: [[TurnEvent]], failure: (any Error)? = nil) {
        state = Mutex(State(rounds: rounds))
        self.failure = failure
    }
    var messages: [[TurnMessage]] { state.withLock { $0.messages } }
    var streaming: StreamingSupport { .incremental }
    func capabilities() async throws -> ModelCapabilities { .init(supportsTools: true) }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("Scripted turns only.")
    }
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let round = state.withLock { state in
            state.messages.append(messages)
            return state.rounds.isEmpty ? [] : state.rounds.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in round { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }
}

@MainActor
func testTurnRunner(host: TestTurnHost, root: URL, allowsSuspension: Bool = true) -> TurnRunner {
    TurnRunner(tools: AutomationTools(session: TurnTestSession()),
               configuration: .init(workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"),
                                    allowsSuspension: allowsSuspension), host: host)
}

func testTurnRoot() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "braus-turn-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
func testTurnInstructions(role: String? = nil) -> String {
    let tools = AutomationTools(session: TurnTestSession())
    return TurnRunner.systemPrompt(role: role, tools: tools.instructions,
        toolNames: tools.toolDefinitions.compactMap { $0["name"].string },
        groupIndex: tools.groupIndex, guidesEnabled: tools.guidesEnabled)
}
