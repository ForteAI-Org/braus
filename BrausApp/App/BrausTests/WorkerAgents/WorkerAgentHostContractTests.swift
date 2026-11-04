import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import LocalMCP
import ModelTransports
import Synchronization
import Testing
import TaskRouting
import Turn
@testable import Braus

@MainActor
@Suite("Worker host turn contract")
struct WorkerAgentHostContractTests {
    private var source: URL {
        var root = URL(filePath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root.deleteLastPathComponent()
        }
        return root
    }

    @Test func commandLineMatchesTheSharedFixture() async throws {
        let fixtures = source.appending(path: "Tests/Turn/Fixtures")
        let root = URL.temporaryDirectory.appending(path: "braus-worker-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let script = root.appending(path: "provider.py")
        try FileManager.default.copyItem(at: fixtures.appending(path: "provider.py"), to: script)
        try FileManager.default.copyItem(at: source.appending(path: "Tests/Chat/Fixtures/claude-turn1.jsonl"),
                                        to: root.appending(path: "reply.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let host = WorkerAgentHost(workingDirectory: root.appending(path: "work"), bridgeExecutable: script,
            session: { DesktopUnavailableSession() }, agents: { _ in (.claude, script) },
            seatLine: { SeatFacts() })
        var replies = ""
        var usage: TurnUsage?
        var calls = 0
        try await host.run(prompt: "Hello", selection: .init(provider: .claudeCode, model: "", effort: .medium),
                           sessionID: nil, role: nil) { event in
            switch event {
            case .provider(.assistant(let text)): replies += text
            case .usage(let count): usage = count
            case .tool(let text): if text.hasPrefix("→") { calls += 1 }
            default: break
            }
        }
        let received = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "received.json")))
        let values = try #require(received["arguments"].array)
        let arguments = values.compactMap { $0.string }
        let index = try #require(arguments.firstIndex(of: "--append-system-prompt"))
        let snapshot = try snapshot(prompt: received["standardInput"], instructions: arguments[index + 1],
                                    reply: replies, calls: calls, usage: #require(usage).turn)
        let expected = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: fixtures.appending(path: "contract-command-line.json")))
        #expect(snapshot == expected)
        try await host.close()
    }

    @Test func loopMatchesTheSharedFixture() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-loop-contract-\(UUID().uuidString)")
        defer { if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        } }
        let transport = ContractLoopTransport()
        let host = WorkerAgentHost(workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"),
            session: { DesktopUnavailableSession() }, agents: { _ in (.claude, URL(filePath: "/bin/cat")) },
            transports: { _ in transport }, seatLine: { SeatFacts() })
        var replies = ""
        var usage: TurnUsage?
        var calls = 0
        try await host.run(prompt: "Hello", selection: .init(provider: .anthropic, model: "", effort: .medium),
                           sessionID: nil, role: nil) { event in
            switch event {
            case .provider(.assistant(let text)): replies += text
            case .usage(let count): usage = count
            case .tool(let text): if text.hasPrefix("→") { calls += 1 }
            default: break
            }
        }
        let messages = try #require(transport.messages.first)
        let snapshot = try snapshot(prompt: .string(#require(messages.last).text),
            instructions: #require(messages.first).text, reply: replies, calls: calls, usage: #require(usage).turn)
        let expected = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: source.appending(path: "Tests/Turn/Fixtures/contract-loop.json")))
        #expect(snapshot == expected)
        try await host.close()
    }

    private func snapshot(prompt: JSONValue, instructions: String, reply: String, calls: Int,
                          usage: ProviderUsage.Tokens) throws -> JSONValue {
        .object(["appText": .bool(instructions == TurnInstructions.compose(role: nil)),
                 "ending": .string("completed"), "prompt": prompt, "reply": .string(reply),
                 "toolCalls": .number(Double(calls)), "usage": try JSONDecoder().decode(JSONValue.self,
                    from: JSONEncoder().encode(TurnTokenUsage(usage)))])
    }
}

private final class ContractLoopTransport: ModelTransport {
    private let state = Mutex((count: 0, messages: [[TurnMessage]]()))
    var messages: [[TurnMessage]] { state.withLock { $0.messages } }
    var streaming: StreamingSupport { .incremental }
    func capabilities() async throws -> ModelCapabilities { .init(supportsTools: true) }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("Scripted turns only.")
    }
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        let first = state.withLock { state in
            state.messages.append(messages)
            state.count += 1
            return state.count == 1
        }
        return AsyncThrowingStream { continuation in
            if first { continuation.yield(.toolCall(.init(id: "one", name: "status", arguments: Data("{}".utf8)))) }
            else { continuation.yield(.delta("ok")) }
            continuation.yield(.completed(.init(inputTokens: 1, outputTokens: 2, duration: .zero)))
            continuation.finish()
        }
    }
}
