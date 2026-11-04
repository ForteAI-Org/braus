import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import LocalMCP
import ModelTransports
import Testing
import TaskRouting
@testable import Braus

@MainActor
@Suite("Worker turn byte replay")
struct WorkerTurnReplayTests {
    @Test(arguments: [ChatProvider.claude, .codex])
    func threeTurnsKeepTheOriginalArgumentsAndInput(_ provider: ChatProvider) async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-worker-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let script = root.appending(path: "provider.py")
        let replies = provider == .claude
            ? #"[{"type":"system","subtype":"init","session_id":"s1"},{"type":"result","result":"ok"}]"#
            : #"[{"type":"thread.started","thread_id":"s1"},{"type":"turn.completed"}]"#
        try Data("""
        #!/usr/bin/python3
        import json, os, sys
        with open(os.path.join(os.path.dirname(__file__), 'received.json'), 'w') as output:
            json.dump({'arguments': sys.argv[1:], 'standardInput': [sys.stdin.read()]}, output)
        for event in json.loads('\(replies)'):
            print(json.dumps(event))
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let work = root.appending(path: "work")
        let host = WorkerAgentHost(workingDirectory: work, bridgeExecutable: script,
            session: { DesktopUnavailableSession() }, agents: { _ in (provider, script) },
            seatLine: { SeatFacts() })
        let selection = ModelSelection(provider: provider == .claude ? .claudeCode : .codex, model: "", effort: .medium)
        for index in 0..<3 {
            if index == 2 {
                let token = try host.suspendForHumanIntervention()
                try host.endHumanIntervention(token)
            }
            try await host.run(prompt: "Hello", selection: selection, sessionID: index == 0 ? nil : "s1",
                role: index == 0 ? nil : "Edit documents.", reviewingHumanIntervention: index == 2,
                inheritedEnvironment: [:]) { _ in }
            let received = try JSONDecoder().decode([String: [String]].self,
                from: Data(contentsOf: root.appending(path: "received.json")))
            let arguments = try #require(received["arguments"])
            let connection: String
            if provider == .claude {
                let offset = try #require(arguments.firstIndex(of: "--mcp-config"))
                let config = try JSONDecoder().decode(JSONValue.self, from: Data(arguments[offset + 1].utf8))
                connection = try #require(config["mcpServers"]["braus"]["args"].array?[2].string)
            } else {
                let config = try #require(arguments.first { $0.hasPrefix("mcp_servers.braus=") })
                let expression = #"[^\"]*/connection-[^\"]+\.json"#
                let range = try #require(config.range(of: expression, options: .regularExpression))
                connection = String(config[range])
            }
            func normalize(_ text: String) -> String {
                var text = text
                for (actual, fixed) in [(connection, "/fake/connection.json"), (script.path, "/fake/bridge"),
                                        (work.path, "/fake/work")] {
                    text = text.replacingOccurrences(
                        of: actual.replacingOccurrences(of: "/", with: "\\/"),
                        with: fixed.replacingOccurrences(of: "/", with: "\\/")
                    )
                        .replacingOccurrences(of: actual, with: fixed)
                }
                return text
            }
            let normalized = received.mapValues { $0.map(normalize) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let actual = try encoder.encode(normalized)
            var source = URL(filePath: #filePath)
            while !FileManager.default.fileExists(atPath: source.appending(path: "Package.swift").path) {
                source.deleteLastPathComponent()
            }
            let expected = try Data(contentsOf: source.appending(path:
                "Tests/Turn/Fixtures/replay-\(provider.rawValue)-\(index + 1).json"))
            #expect(actual == expected)
        }
        try await host.close()
    }
}
