import ChatCore
import CLIProviders
import Foundation
import Testing

struct ProviderInvocationTests {
    private func turn(_ provider: ChatProvider, loading: ToolLoading = .upfront,
                      web: Bool = false, compact: Bool = false) -> ProviderTurn {
        ProviderTurn(provider: provider, model: nil, sessionID: nil, prompt: "p", instructions: "i",
            bridgeExecutable: "/b", connectionFile: "/c", workingDirectory: "/w",
            isCompaction: compact, allowsWebSearch: web, toolLoading: loading)
    }

    @Test func upfrontIsToday() throws {
        let value = turn(.claude)
        #expect(value.toolLoading == .upfront)
        #expect(try ProviderInvocation(value).arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config",
            #"{"mcpServers":{"braus":{"args":["mcp-bridge","--connection","\/c"],"command":"\/b"}}}"#,
            "--tools", "", "--allowedTools", "mcp__braus__*", "--permission-mode", "dontAsk",
            "--setting-sources", "", "--disable-slash-commands", "--no-chrome", "--append-system-prompt", "i"
        ])
    }

    @Test func harnessSearchAddsOnlyToolSearch() throws {
        for web in [false, true] {
            for compact in [false, true] {
                let args = try ProviderInvocation(turn(.claude, loading: .harnessSearch, web: web, compact: compact)).arguments
                let tools = args[try #require(args.firstIndex(of: "--tools")) + 1]
                let allowed = args[try #require(args.firstIndex(of: "--allowedTools")) + 1]
                let suffix = web && !compact ? ",WebSearch,WebFetch" : ""
                #expect(tools == (compact ? "" : "ToolSearch") + suffix)
                #expect(allowed == "mcp__braus__*" + (compact ? "" : ",ToolSearch") + suffix)
                let config = args[try #require(args.firstIndex(of: "--mcp-config")) + 1]
                let json = try JSONDecoder().decode(JSONValueForConfig.self, from: Data(config.utf8))
                #expect(json.mcpServers["braus"]?.alwaysLoad == (compact ? nil : false))
            }
        }
    }

    @Test func codexIgnoresToolLoading() throws {
        for web in [false, true] {
            for compact in [false, true] {
                #expect(try ProviderInvocation(turn(.codex, loading: .upfront, web: web, compact: compact)).arguments
                    == ProviderInvocation(turn(.codex, loading: .harnessSearch, web: web, compact: compact)).arguments)
            }
        }
    }
}

private struct JSONValueForConfig: Decodable {
    struct Server: Decodable { let alwaysLoad: Bool? }
    let mcpServers: [String: Server]
}
