import AutomationMCP
import ChatCore
import CLIProviders
import Foundation
import LocalMCP
import Testing

@MainActor
@Suite("Stable prompt across chat turns", .timeLimit(.minutes(1)))
struct StablePromptAcrossTurnsTests {
    /// Normalizes only the resume pair and the connection path, preserving every other byte.
    private func normalized(_ arguments: [String], connection: String, provider: ChatProvider) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == (provider == .claude ? "--resume" : "resume") { index += 2 }
            else {
                let escaped = connection.replacingOccurrences(of: "/", with: "\\/")
                result.append(arguments[index]
                    .replacingOccurrences(of: escaped, with: "<connection>")
                    .replacingOccurrences(of: connection, with: "<connection>"))
                index += 1
            }
        }
        return result
    }

    @Test(arguments: [ChatProvider.claude, .codex])
    func providerArgumentsStayStableAcrossTurns(_ provider: ChatProvider) throws {
        func turn(_ session: String?, connection: String, prompt: String) -> ProviderTurn {
            ProviderTurn(
                provider: provider, model: nil, sessionID: session, prompt: prompt,
                instructions: AutomationTools.instructions, bridgeExecutable: "/fake/bridge",
                connectionFile: connection, workingDirectory: "/tmp", environment: [:]
            )
        }
        let first = turn(nil, connection: "/tmp/connection-one.json", prompt: "First request")
        let second = turn("s1", connection: "/tmp/connection-two.json", prompt: "Second request")
        let before = try ProviderInvocation(first).arguments
        let after = try ProviderInvocation(second).arguments
        #expect(first.instructions.utf8.elementsEqual(second.instructions.utf8))
        #expect(normalized(before, connection: first.connectionFile, provider: provider)
                == normalized(after, connection: second.connectionFile, provider: provider))
        #expect(try connection(in: before, provider: provider) == first.connectionFile)
        #expect(try connection(in: after, provider: provider) == second.connectionFile)
    }

    private func connection(in arguments: [String], provider: ChatProvider) throws -> String {
        if provider == .claude {
            let index = try #require(arguments.firstIndex(of: "--mcp-config"))
            let config = try JSONDecoder().decode(JSONValue.self, from: Data(arguments[index + 1].utf8))
            return try #require(config["mcpServers"]["braus"]["args"].array?[2].string)
        }
        let config = try #require(arguments.first { $0.hasPrefix("mcp_servers.braus=") })
        let start = try #require(config.range(of: "connection-"))
        let end = try #require(config.range(of: ".json", range: start.lowerBound..<config.endIndex))
        let prefix = config[..<start.lowerBound]
        let quote = try #require(prefix.lastIndex(of: "\""))
        return String(config[config.index(after: quote)..<end.upperBound])
    }

    @Test(arguments: [ChatProvider.claude, .codex])
    func twoActualTurnsKeepArgumentsAndUseDifferentConnectionFiles(_ provider: ChatProvider) async throws {
        let result = try await ChatChildProcess.run(provider: provider.rawValue, messages: "First request\n\n> Second request")
        try #require(result.status == 0, Comment(rawValue: result.output))
        try #require(result.arguments.count == 2)
        let first = result.arguments[0], second = result.arguments[1]
        let old = try connection(in: first, provider: provider)
        let new = try connection(in: second, provider: provider)
        #expect(old != new)
        #expect(normalized(first, connection: old, provider: provider)
                == normalized(second, connection: new, provider: provider))
        if provider == .claude {
            let index = try #require(first.firstIndex(of: "--append-system-prompt"))
            #expect(first[index + 1] == second[index + 1])
            #expect(!first[index + 1].contains(old))
            #expect(!first[index + 1].contains(new))
            let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
            #expect(first[index + 1].range(of: uuid, options: .regularExpression) == nil)
            let date = #"20[0-9]{2}-[0-9]{2}-[0-9]{2}"#
            #expect(first[index + 1].range(of: date, options: .regularExpression) == nil)
        }
    }
}
