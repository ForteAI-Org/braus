import AutomationMCP
import ChatCore
import Foundation
import LocalMCP
import ModelTransports
import Testing
@testable import Turn

@MainActor
@Suite("TurnTests reminder usage")
struct TurnReminderUsageTests {
    @Test func loopReminderIsIncludedInTheSingleFinalCount() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        var reminders = ["Interpret candidate c1."]
        let runner = TurnRunner(tools: AutomationTools(session: TurnTestSession()),
            configuration: .init(workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"),
                                 allowsSuspension: true), host: host, reminder: { reminders.popLast() })
        let transport = TurnTestTransport([
            [.delta("First."), .completed(.init(inputTokens: 10, outputTokens: 3, duration: .zero))],
            [.delta("Done."), .completed(.init(inputTokens: 20, outputTokens: 4, duration: .zero))]
        ])
        var events: [TurnRunEvent] = []
        let outcome = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { events.append($0) }
        #expect(outcome.usage?.tokens == .init(input: 30, output: 7))
        #expect(outcome.rounds == 2)
        #expect(transport.messages.last?.last?.text == "Interpret candidate c1.")
        #expect(events.filter { if case .usage = $0 { true } else { false } }.count == 1)
        try await runner.close()
    }

    @Test func commandLineReminderAddsOnlyItsOwnSessionDifference() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let script = root.appending(path: "provider.py")
        try Data("""
        #!/usr/bin/python3
        import json, os, sys
        prompt = sys.stdin.read()
        print(json.dumps({'type': 'thread.started', 'thread_id': 's1'}))
        total = 1150 if prompt == 'Interpret candidate c1.' else 1000
        print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': total, 'output_tokens': 0}}))
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let host = TestTurnHost()
        var reminders = ["Interpret candidate c1."]
        let runner = TurnRunner(tools: AutomationTools(session: TurnTestSession()),
            configuration: .init(workingDirectory: root, bridgeExecutable: script, allowsSuspension: true),
            host: host, reminder: { reminders.popLast() })
        var events: [TurnRunEvent] = []
        let outcome = try await runner.run(.init(prompt: "Hello", route: .commandLine(provider: .codex,
            executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { events.append($0) }
        #expect(outcome.usage?.total == 1150)
        #expect(outcome.lastReported?.tokens.input == 1150)
        #expect(outcome.rounds == 2)
        #expect(events.filter { if case .usage = $0 { true } else { false } }.count == 1)
        try await runner.close()
    }
}
