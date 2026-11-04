import AutomationMCP
import ChatCore
import LocalMCP
import Foundation
import ModelTransports
import Testing
import Turn

@MainActor
@Suite("TurnTests host contract")
struct TurnHostContractTests {
    static let allowedDifferences = ["allowsSuspension"]

    @Test func loopKeepsItsSingleFinalUsageEvent() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([[
            .delta("Done."), .completed(.init(inputTokens: 10, outputTokens: 2, duration: .zero))
        ]])
        var events: [TurnRunEvent] = []
        let outcome = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: 4096), role: "Edit documents.")) { events.append($0) }
        #expect(transport.messages.first?.first?.text == testTurnInstructions(role: "Edit documents."))
        #expect(transport.messages.first?.last?.text == "<braus_state>\nsession: closed\ntask: none\n</braus_state>\n\nHello")
        #expect(outcome.usage?.total == 12)
        #expect(outcome.rounds == 1)
        #expect(events.last == .usage(.init(tokens: .init(input: 10, output: 2), contextTokens: 12,
                                          contextWindow: 4096), TurnTokenUsage(.init(input: 10, output: 2))))
        try await runner.close()
    }
}

extension TurnHostContractTests {
    @Test(arguments: [true, false])
    func commandLineHostsHaveTheSameContract(_ allowsSuspension: Bool) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let source = URL(filePath: #filePath).deletingLastPathComponent()
        let fixtures = source.appending(path: "Fixtures")
        let script = root.appending(path: "provider.py")
        try FileManager.default.copyItem(at: fixtures.appending(path: "provider.py"), to: script)
        try FileManager.default.copyItem(at: source.deletingLastPathComponent().appending(path: "Chat/Fixtures/claude-turn1.jsonl"),
                                        to: root.appending(path: "reply.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root.appending(path: "work"), allowsSuspension: allowsSuspension)
        var replies = ""
        let outcome = try await runner.run(.init(prompt: "Hello", route: .commandLine(provider: .claude,
            executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { event in
            if case .provider(.assistant(let text)) = event { replies += text }
        }
        let received = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "received.json")))
        let values = try #require(received["arguments"].array)
        let arguments = values.compactMap { $0.string }
        let index = try #require(arguments.firstIndex(of: "--append-system-prompt"))
        let snapshot: JSONValue = .object([
            "appText": .bool(arguments[index + 1] == testTurnInstructions()),
            "ending": .string("completed"), "prompt": received["standardInput"],
            "reply": .string(replies), "toolCalls": .number(Double(outcome.toolCalls)),
            "usage": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(outcome.usage))
        ])
        let expected = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: fixtures.appending(path: "contract-command-line.json")))
        #expect(snapshot == expected)
        try await runner.close()
    }
}

extension TurnHostContractTests {
    @Test func loopMatchesTheSharedFixture() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "one", name: "observe", arguments: Data("{}".utf8))),
             .completed(.init(inputTokens: 1, outputTokens: 2, duration: .zero))],
            [.delta("ok"), .completed(.init(inputTokens: 1, outputTokens: 2, duration: .zero))]
        ])
        var replies = ""
        let outcome = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { event in
            if case .provider(.assistant(let text)) = event { replies += text }
        }
        let messages = try #require(transport.messages.first)
        let snapshot: JSONValue = .object([
            "appText": .bool(messages.first?.text == testTurnInstructions()),
            "ending": .string("completed"), "prompt": .string(try #require(messages.last).text),
            "reply": .string(replies), "toolCalls": .number(Double(outcome.toolCalls)),
            "usage": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(outcome.usage))
        ])
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
            URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/contract-loop.json")))
        #expect(snapshot == expected)
        try await runner.close()
    }
}

extension TurnHostContractTests {
    @Test func structuredFactsHaveTheSamePromptInBothHosts() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let source = URL(filePath: #filePath).deletingLastPathComponent()
        let script = root.appending(path: "provider.py")
        try FileManager.default.copyItem(at: source.appending(path: "Fixtures/provider.py"), to: script)
        try FileManager.default.copyItem(at: source.deletingLastPathComponent()
            .appending(path: "Chat/Fixtures/claude-turn1.jsonl"), to: root.appending(path: "reply.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let host = TestTurnHost()
        let app = testTurnRunner(host: host, root: root.appending(path: "app"))
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1,
            outputTokens: 1, duration: .zero))]])
        _ = try await app.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil), reviewingHumanIntervention: true)) { _ in }
        let cli = testTurnRunner(host: host, root: root.appending(path: "cli"), allowsSuspension: false)
        _ = try await cli.run(.init(prompt: "Hello", route: .commandLine(provider: .claude,
            executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false),
            reviewingHumanIntervention: true)) { _ in }
        let received = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: root.appending(path: "received.json")))
        #expect(received["standardInput"].string == transport.messages.first?.last?.text)
        try await app.close()
        try await cli.close()
    }
}

extension TurnHostContractTests {
    @Test func directNameOutsideProfileIsRefusedByRunner() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "one", name: "status", arguments: Data("{}".utf8))),
             .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))],
            [.delta("done"), .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]
        ])
        _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { _ in }
        #expect(transport.messages.dropFirst().flatMap { $0 }.contains { $0.text.contains("Unknown tool.") })
        try await runner.close()
    }
}


extension TurnHostContractTests {
    @Test func malformedArgumentsCountAsAttemptsWithoutDoubleCountingDecodedCalls() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let tools = AutomationTools(session: TurnTestSession())
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: true), host: host)
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "bad", name: "act", arguments: Data("{".utf8))),
             .toolCall(.init(id: "read", name: "observe", arguments: Data("{}".utf8))),
             .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))],
            [.delta("Reported."), .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]
        ])
        _ = try await runner.run(.init(prompt: "Inspect the synthetic state", route: .modelLoop(
            transport: transport, contextWindow: nil))) { _ in }
        #expect(tools.configurationEvidence["tool_attempts"]["act"] == .number(1))
        #expect(tools.configurationEvidence["tool_attempts"]["observe"] == .number(1))
        #expect(tools.configurationEvidence["tool_attempts"].object?.count == 2)
        #expect(transport.messages.last?.filter { $0.role == .tool }.count == 2)
        try await runner.close()
    }
}
