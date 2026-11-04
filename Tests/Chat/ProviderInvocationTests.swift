import ChatCore
import CLIProviders
import Foundation
import Testing

struct ProviderInvocationTests {
    private func turn(_ provider: ChatProvider, web: Bool = false, compact: Bool = false) -> ProviderTurn {
        ProviderTurn(provider: provider, model: nil, sessionID: nil, prompt: "p", instructions: "i",
            bridgeExecutable: "/b", connectionFile: "/c", workingDirectory: "/w",
            isCompaction: compact, allowsWebSearch: web)
    }

    @Test func fixedMCPInvocationHasNoProviderToolSearch() throws {
        #expect(try ProviderInvocation(turn(.claude)).arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config",
            #"{"mcpServers":{"braus":{"args":["mcp-bridge","--connection","\/c"],"command":"\/b"}}}"#,
            "--tools", "", "--allowedTools", "mcp__braus__*", "--permission-mode", "dontAsk",
            "--setting-sources", "", "--disable-slash-commands", "--no-chrome", "--append-system-prompt", "i"
        ])
    }

    @Test func webCapabilityDoesNotEnableNativeToolDiscovery() throws {
        for web in [false, true] {
            for compact in [false, true] {
                let invocation = try ProviderInvocation(turn(.claude, web: web, compact: compact))
                let args = invocation.arguments
                let enabled = web && !compact
                let tools = args[try #require(args.firstIndex(of: "--tools")) + 1]
                let allowed = args[try #require(args.firstIndex(of: "--allowedTools")) + 1]
                #expect(tools == (enabled ? "WebSearch,WebFetch" : ""))
                #expect(allowed == "mcp__braus__*" + (enabled ? ",WebSearch,WebFetch" : ""))
                #expect(!args.contains { $0.contains("ToolSearch") })
                let config = args[try #require(args.firstIndex(of: "--mcp-config")) + 1]
                let json = try JSONDecoder().decode(JSONValueForConfig.self, from: Data(config.utf8))
                #expect(json.mcpServers["braus"]?.alwaysLoad == nil)
                #expect(invocation.standardInput == (compact ? "/compact" : "p"))
            }
        }
    }

    @Test func codexKeepsTheSingleExplicitMCPServerAndWebPermission() throws {
        for web in [false, true] {
            for compact in [false, true] {
                let args = try ProviderInvocation(turn(.codex, web: web, compact: compact)).arguments
                #expect(args.filter { $0.hasPrefix("mcp_servers.") }.count == 1)
                #expect(args.contains { $0.hasPrefix("mcp_servers.braus=") })
                #expect(args.contains("web_search=\"\(web && !compact ? "live" : "disabled")\""))
                #expect(!args.contains { $0.contains("ToolSearch") || $0.contains("alwaysLoad") })
            }
        }
    }
}

private struct JSONValueForConfig: Decodable {
    struct Server: Decodable { let alwaysLoad: Bool? }
    let mcpServers: [String: Server]
}
