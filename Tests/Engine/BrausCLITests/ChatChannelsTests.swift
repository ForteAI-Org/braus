import AppAdapters
import AutomationMCP
import AutomationRuntime
import ChatCore
import FileConversations
import Foundation
import LocalMCP
import Memory
import Router
import SeatBroker
import Testing
import WebDriver
import WebSession
@testable import braus

/// P10 verifies the chat's requested web routes on temporary folders. A synthetic provider sends the refusal
/// requests through the real MCP bridge; no Chrome is launched, and no account or Seat is used.
@MainActor
@Suite("P10: the chat composes the web routes it is asked for, and refuses the rest")
struct ChatChannelsTests {

    /// A chat on temporary folders with `arguments`, removed by `end`.
    final class Chat {
        let root = URL.temporaryDirectory.appending(path: "braus-chat-channels-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        let history: URL
        let session: ChatSession

        init(_ arguments: [String], provider: URL? = nil, adapters: AppAdapters? = nil) throws {
            let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
            history = root.appending(path: "History", directoryHint: .isDirectory)
            for directory in [knowledge, history] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let options = try ChatOptions(arguments: ["--knowledge", knowledge.path(percentEncoded: false),
                                                      "--history-dir", history.path(percentEncoded: false)]
                                                     + arguments)
            session = try ChatSession(options: options, history: history, executable: provider ?? URL(filePath: "/usr/bin/false"),
                                      bridgeExecutable: try Self.brausExecutable(), adapters: adapters)
        }

        /// SwiftPM's host is a test helper, so the bridge must use the built CLI explicitly.
        static func brausExecutable() throws -> URL {
            if let path = ProcessInfo.processInfo.environment["BRAUS_TEST_BRAUS"], !path.isEmpty {
                let executable = URL(filePath: path)
                try #require(FileManager.default.isExecutableFile(atPath: executable.path))
                return executable
            }
            var root = URL(filePath: #filePath)
            for _ in 0..<4 { root.deleteLastPathComponent() }
            for products in [".build/debug", ".build/out/Products/Debug"] {
                let executable = root.appending(path: products).appending(path: "braus")
                if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            }
            throw CocoaError(.fileNoSuchFile)
        }

        /// Starts a synthetic provider which uses the real MCP bridge and persists its answers outside the chat.
        static func provider(in folder: URL, requests: [LocalMCP.JSONValue]) throws -> URL {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoded = try JSONEncoder().encode(requests).base64EncodedString()
            let script = folder.appending(path: "provider.py")
            let body = """
            #!/usr/bin/python3
            import base64, json, os, subprocess, sys
            args = sys.argv[1:]
            sys.stdin.read()
            server = json.loads(args[args.index('--mcp-config') + 1])['mcpServers']['braus']
            with open(os.path.join(os.path.dirname(__file__), 'bridge-command.json'), 'w') as file:
                json.dump(server, file)
            bridge = subprocess.Popen([server['command']] + server['args'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            def ask(number, method, params):
                bridge.stdin.write((json.dumps({'jsonrpc':'2.0','id':number,'method':method,'params':params}) + '\\n').encode())
                bridge.stdin.flush()
                while True:
                    line = bridge.stdout.readline()
                    if not line:
                        raise RuntimeError('Bridge closed before answering')
                    answer = json.loads(line)
                    if answer.get('id') == number:
                        return answer
            ask(1, 'initialize', {'protocolVersion':'2025-11-25'})
            requests = json.loads(base64.b64decode('\(encoded)'))
            answers = [ask(index + 2, 'tools/call', request) for index, request in enumerate(requests)]
            with open(os.path.join(os.path.dirname(__file__), 'answers.json'), 'w') as file:
                json.dump(answers, file)
            bridge.stdin.close()
            bridge.wait(timeout=10)
            for event in [{'type':'system','subtype':'init','session_id':'synthetic'},
                          {'type':'assistant','message':{'content':[{'type':'text','text':'Synthetic requests completed.'}]}},
                          {'type':'result','is_error':False,'result':'Synthetic requests completed.','session_id':'synthetic'}]:
                print(json.dumps(event), flush=True)
            """
            try Data(body.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return script
        }

        func runProvider(in folder: URL) async throws -> [LocalMCP.JSONValue] {
            let store = try ConversationStore(directory: history.appending(path: "Conversations"))
            session.adopt(ChatTranscript(conversation: Conversation(provider: .claude, model: nil), store: store))
            try await session.turn("Run the synthetic requests.")
            let command = try JSONDecoder().decode(LocalMCP.JSONValue.self,
                from: Data(contentsOf: folder.appending(path: "bridge-command.json")))
            #expect(command["command"].string == (try Self.brausExecutable()).path)
            #expect(command["args"].array?.first == .string("mcp-bridge"))
            return try JSONDecoder().decode([LocalMCP.JSONValue].self,
                from: Data(contentsOf: folder.appending(path: "answers.json")))
        }

        var support: URL { root.appending(path: "Support", directoryHint: .isDirectory) }

        func end() async {
            await session.finish()
            session.stop()
            await MemoryService.closeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func text(_ result: LocalMCP.JSONValue) -> String { result["content"].array?.first?["text"].string ?? "" }

    @Test("--chrome goes with --channels web, by absolute path")
    func chromeNeedsTheWebChannel() {
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--chrome", "/tmp/chrome"]) }
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--channels", "web", "--chrome", "chrome"]) }
        #expect((try? ChatOptions(arguments: ["--channels", "web", "--chrome", "/tmp/chrome"]))?.chromeExecutable
                == "/tmp/chrome")
    }

    @Test("without --channels, the Seat alone")
    func nothingByDefault() async throws {
        let chat = try Chat([])
        #expect(chat.session.web == nil)
        #expect(!(chat.session.tools.session is RoutingAutomationSession))
        await chat.end()
    }

    @Test("web: the chat's own headless Chrome on a profile under its history folder, the route for addresses")
    func webIsTheChatsOwnChrome() async throws {
        let chat = try Chat(["--channels", "web", "--chrome", "/tmp/braus-test-chrome"])
        let web = try #require(chat.session.web)
        let routing = try #require(chat.session.tools.session as? RoutingAutomationSession)
        #expect(routing.web === web && routing.native == nil)
        #expect(web.launchOptions.userDataDirectory.standardizedFileURL
                == chat.history.appending(path: "Chrome", directoryHint: .isDirectory).standardizedFileURL)
        #expect(web.launchOptions.isHeadless)
        #expect(web.launchOptions.executableURL.path == "/tmp/braus-test-chrome")
        #expect(web.launchOptions.additionalArguments.isEmpty, "no flag weakens the profile's keychain")
        #expect(!web.usesPersonalChrome && web.chromeProfile == nil)
        await chat.end()
    }

    @Test("web: the person's own Chrome and a paired profile are refused, with nothing opened", arguments: ["personal", "profile"])
    func personalChromeAndProfilesAreRefused(_ mode: String) async throws {
        let folder = URL.temporaryDirectory.appending(path: "chat-web-refusal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = try Chat.provider(in: folder, requests: [.object([
            "name": .string("open_session"), "arguments": .object(["app": .string("http://127.0.0.1:9/")])
        ])])
        let chat = try Chat(["--channels", "web", "--chrome", "/tmp/braus-test-chrome-absent"], provider: provider)
        let web = try #require(chat.session.web)
        if mode == "personal" { web.usesPersonalChrome = true }
        else { web.chromeProfile = ChromeProfileChoice(instanceID: "p1", label: "Work") }
        do {
            let answers = try await chat.runProvider(in: folder)
            let answer = try #require(answers.first)
            #expect(answer["error"] != .null || answer["result"]["isError"] == .bool(true), "\(answer)")
        } catch {
            await chat.end()
            throw error
        }
        #expect(web.id == nil, "nothing opened")
        await chat.end()
    }

}
