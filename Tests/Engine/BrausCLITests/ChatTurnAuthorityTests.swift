import AutomationRuntime
import ChatCore
import CLIProviders
import EngineCore
import FileConversations
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import TestScratch
import Testing
@testable import braus

/// I02 on the command line: a chat turn's authority is the turn's own. Each turn of `ChatSession` has a loopback host,
/// a token and a connection file of its own, admitted only while it runs; a client or a file of an earlier turn, or of
/// the conversation before, acts on nothing between turns or in a later one, while the new turn's own client works.
/// A session ID given before `releaseSeat` acts on nothing afterwards, and a failed turn finishes its call in flight
/// and runs nothing again.
///
/// Offline: the real `ChatSession` on temporary folders, never `start`ed (no signal handling), over a counting session
/// in place of its desktop (no Seat, input or account); a stand-in Claude Code that notes its connection file and
/// answers, or fails, once its `go-N` file exists, for at most a minute; the built `braus-bridge` as the clients
/// (`BridgeProcess`), each stopped only by the PID this test started it with.
@MainActor
@Suite("I02: a chat turn's authority is its own", .serialized, .timeLimit(.minutes(2)))
struct ChatTurnAuthorityTests {

    /// A desktop in place of the Seat that counts what reaches it. `open` opens a session under a new ID, after
    /// `release` while `holds`; `close` ends it.
    final class CountingSession: AutomationSessionOperating {
        private(set) var id: UUID?
        var calls: [String] = []
        var holds = false
        private var gate: CheckedContinuation<Void, Never>?

        func open(application: String, window: String?) async throws -> SceneSnapshot {
            calls.append("open")
            if holds { await withCheckedContinuation { gate = $0 } }
            id = UUID()
            return SceneSnapshot(bundleID: "com.example.notes", appName: "Notes", windowTitle: "Notes",
                                 viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        }
        func observe() async throws -> SceneSnapshot {
            calls.append("observe")
            throw AutomationFailure("Nothing to observe here.")
        }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
            -> ActOutcome {
            calls.append("act")
            guard id != nil else { throw AutomationFailure("Nothing is open.") }
            return ActOutcome(.foundActed, "acted on \(target)")
        }
        func select(control: String, item: String) async throws -> ActOutcome {
            calls.append("select")
            throw AutomationFailure("Nothing is open.")
        }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
            calls.append("deliver")
            throw AutomationFailure("Nothing is open.")
        }
        func close() async { id = nil }

        var isHeld: Bool { gate != nil }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    /// One test's folders, its stand-in, its session and the bridges it started, all ended on every path.
    final class Chat {
        let root = URL.temporaryDirectory.appending(path: "braus-chat-turns-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        let counting = CountingSession()
        let session: ChatSession
        let store: ConversationStore
        private var bridges: [BridgeProcess] = []

        var agent: URL { root.appending(path: "claude") }

        init() throws {
            let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
            let history   = root.appending(path: "History", directoryHint: .isDirectory)
            for directory in [knowledge, history, root.appending(path: "log")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data(Self.script(root).utf8).write(to: root.appending(path: "claude"))
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: root.appending(path: "claude").path)
            let options = try ChatOptions(arguments: ["--knowledge", knowledge.path(percentEncoded: false),
                                                      "--history-dir", history.path(percentEncoded: false)])
            let counting = self.counting
            session = try ChatSession(options: options, history: history, executable: root.appending(path: "claude"),
                                      session: { _ in counting })
            store = try ConversationStore(directory: root.appending(path: "Conversations", directoryHint: .isDirectory))
        }

        /// Call N notes its connection file in `connection-N`, then, once `go-N` exists, answers "ok", or fails
        /// when `go-N` says `fail`. It gives up after a minute.
        static func script(_ root: URL) -> String {
            """
            #!/usr/bin/python3
            import json, os, sys, time
            root = '\(root.path)'
            sys.stdin.read()
            log = os.path.join(root, 'log')
            call = len(os.listdir(log))
            open(os.path.join(log, '%03d' % call), 'w').close()
            config = json.loads(sys.argv[sys.argv.index('--mcp-config') + 1])
            noted = os.path.join(root, 'noted-%d' % os.getpid())
            with open(noted, 'w') as file:
                file.write(config['mcpServers']['braus']['args'][2])
            os.replace(noted, os.path.join(root, 'connection-%d' % call))
            def say(event):
                event['session_id'] = 's1'
                print(json.dumps(event), flush=True)
            say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
            go = os.path.join(root, 'go-%d' % call)
            deadline = time.time() + 60
            while not os.path.exists(go):
                if time.time() > deadline:
                    sys.exit(1)
                time.sleep(0.01)
            if open(go).read() == 'fail':
                sys.exit(1)
            say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
            say({'type': 'result', 'is_error': False, 'result': 'ok'})

            """
        }

        /// A new conversation, adopted as the chat's current one.
        func adoptNew() throws {
            let transcript = ChatTranscript(conversation: Conversation(provider: .claude, model: nil), store: store)
            try transcript.save()
            session.adopt(transcript)
        }

        /// The connection file call `call` was given, once it started.
        func connection(of call: Int) async throws -> URL {
            let noted = root.appending(path: "connection-\(call)")
            let started = try await BridgeProcess.eventually { FileManager.default.fileExists(atPath: noted.path) }
            try #require(started, "call \(call) started")
            return URL(fileURLWithPath: try String(contentsOf: noted, encoding: .utf8))
        }

        func go(_ call: Int, failing: Bool = false) throws {
            try Data((failing ? "fail" : "").utf8).write(to: root.appending(path: "go-\(call)"))
        }

        /// A client on `connection`, held until the test ends.
        func client(_ connection: URL) throws -> BridgeProcess {
            let bridge = try BridgeProcess(executable: try ChatTurnAuthorityTests.bridge(), connection: connection,
                                           root: root, index: bridges.count)
            bridges.append(bridge)
            return bridge
        }

        /// Runs `body`, then, whatever happened, stops the session's provider, the bridges by their PIDs, the session
        /// and its turn host, and removes the folders.
        func running(_ body: @MainActor () async throws -> Void) async throws {
            do { try await body() } catch {
                await end()
                throw error
            }
            await end()
        }

        private func end() async {
            counting.release()
            // The session's own stand-in, if a turn still runs: stopped and waited for, not left to its deadline.
            session.provider.cancel()
            await session.provider.waitUntilStopped()
            for bridge in bridges { _ = await bridge.stop() }
            bridges = []
            await session.releaseSeat()
            session.stop()
            await MemoryService.closeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The built `braus-bridge`, beside this test bundle, or the one `BRAUS_TEST_BRIDGE` names.
    static func bridge() throws -> URL {
        if let named = ProcessInfo.processInfo.environment["BRAUS_TEST_BRIDGE"], !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        let bundle = try #require(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
        let built = bundle.bundleURL.deletingLastPathComponent().appending(path: "braus-bridge")
        try #require(FileManager.default.isExecutableFile(atPath: built.path), "build braus-bridge: \(built.path)")
        return built
    }

    /// One `tools/call` through `bridge`, or nil when no answer came: the connection closed or refused.
    static func call(_ bridge: BridgeProcess, _ name: String, _ arguments: JSONValue = .object([:])) async
        -> JSONValue? {
        try? await bridge.ask("tools/call", .object(["name": .string(name), "arguments": arguments]))
    }

    /// Whether the router let the call reach Braus's tools.
    static func admitted(_ answer: JSONValue?) -> Bool { answer?["result"].object != nil }

    /// The session ID an `open_session` answer gives.
    static func sessionID(_ answer: JSONValue?) -> String? {
        guard let text = answer?["result"]["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        return value["session"].string
    }

    static let open: JSONValue = .object(["app": .string("Notes")])

    final class Flag { var isSet = false }

    static func act(_ id: String) -> JSONValue { .object(["session": .string(id), "target": .string("B3")]) }

    @Test("an earlier turn's client and file act on nothing between turns, after the next conversation is adopted or during its turn; its own client works; an ID given before releaseSeat acts on nothing")
    func aTurnsAuthorityIsItsOwn() async throws {
        let chat = try Chat()
        try await chat.running {
            try chat.adoptNew()
            let first = Task { try await chat.session.turn("one") }
            let old = try await chat.connection(of: 0)
            let held = try chat.client(old)
            let oldID = try #require(Self.sessionID(await Self.call(held, "open_session", Self.open)))
            #expect(Self.admitted(await Self.call(held, "act", Self.act(oldID))))
            #expect(chat.counting.calls == ["open", "act"])
            try chat.go(0)
            try await first.value

            #expect(!Self.admitted(await Self.call(held, "act", Self.act(oldID))), "the held client, between turns")
            #expect(!Self.admitted(await Self.call(try chat.client(old), "act", Self.act(oldID))), "its file")
            await chat.session.releaseSeat()
            #expect(chat.counting.id == nil, "releaseSeat closed the session")
            #expect(!Self.admitted(await Self.call(held, "status")), "nothing resumes after releaseSeat")
            try chat.adoptNew()
            #expect(!Self.admitted(await Self.call(try chat.client(old), "status")), "nor after a new conversation")
            #expect(chat.counting.calls.count == 2)

            let second = Task { try await chat.session.turn("two") }
            let new = try await chat.connection(of: 1)
            #expect(new != old, "the turn has a connection of its own")
            #expect(!Self.admitted(await Self.call(held, "act", Self.act(oldID))), "the held client, in the next turn")
            #expect(!Self.admitted(await Self.call(try chat.client(old), "act", Self.act(oldID))), "its file, too")
            let client = try chat.client(new)
            let stale = await Self.call(client, "act", Self.act(oldID))
            #expect(Self.admitted(stale) && stale?["result"]["isError"] == .bool(true), "the old ID is refused")
            #expect(chat.counting.calls.count == 2, "nothing reached the session for the old client, file or ID")
            let newID = try #require(Self.sessionID(await Self.call(client, "open_session", Self.open)))
            #expect(newID != oldID)
            #expect(Self.admitted(await Self.call(client, "act", Self.act(newID))))
            #expect(chat.counting.calls == ["open", "act", "open", "act"])
            try chat.go(1)
            try await second.value
            #expect(!Self.admitted(await Self.call(client, "status")), "nothing once that turn ended either")
        }
    }

    @Test("a turn that fails while a call waits ends only once that call finished, and nothing runs again or is admitted after")
    func aFailedTurnRunsNothingAgain() async throws {
        let chat = try Chat()
        try await chat.running {
            try chat.adoptNew()
            chat.counting.holds = true
            let ended = Flag()
            let turn = Task {
                defer { ended.isSet = true }
                try await chat.session.turn("one")
            }
            let connection = try await chat.connection(of: 0)
            let client = try chat.client(connection)
            let waiting = Task { await Self.call(client, "open_session", Self.open) }
            let reached = try await BridgeProcess.eventually { chat.counting.isHeld }
            try #require(reached, "the call reached the session and waits")
            try chat.go(0, failing: true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!ended.isSet, "the failed turn waits for the call in flight")
            chat.counting.release()
            await #expect(throws: (any Error).self) { try await turn.value }
            #expect(Self.admitted(await waiting.value), "the call in flight finished")
            #expect(chat.counting.calls == ["open"], "nothing ran again")
            #expect(!Self.admitted(await Self.call(try chat.client(connection), "open_session", Self.open)))
            #expect(chat.counting.calls == ["open"])
        }
    }
}
