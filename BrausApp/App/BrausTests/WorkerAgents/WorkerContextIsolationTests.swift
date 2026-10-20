//
//  WorkerContextIsolationTests.swift
//  Braus
//

import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import ModelTransports
import PerceptionCore
import SeatBroker
import Testing
@testable import Braus

/// I02: a worker acts in one context at a time. A host's tools are admitted only while one of its command line's turns
/// runs, so a connection left from an ended turn, or from a conversation the worker left, acts on nothing; Stop ends
/// a turn with its call in flight finished and nothing replayed; and a worker that goes A→B→A keeps one desktop,
/// each conversation its own host, with B's context retired as A starts again.
///
/// Offline: a stand-in Claude Code that notes its connection file and answers once its `go-N` file exists, Braus's own
/// bridge as the lingering client, and a counting session in place of the desktop where a call must reach one. No
/// account, grant, window or seat: the team test only reads `status`.
@MainActor
@Suite("I02: a worker's contexts", .serialized, .timeLimit(.minutes(2)))
struct WorkerContextIsolationTests {

    static let selection = ModelSelection(provider: .claudeCode, model: "claude-sonnet-5", effort: .low)

    /// A temporary folder with the stand-in Claude Code in it, removed by `remove`.
    struct StandIn {
        let root  = URL.temporaryDirectory.appending(path: "braus-contexts-\(UUID().uuidString)")
        var agent : URL { root.appending(path: "claude") }

        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: "log"), withIntermediateDirectories: true)
            try Data(Self.script(root).utf8).write(to: agent)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        }

        /// Call N notes its connection file in `connection-N`, then answers "ok" once `go-N` exists.
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
            connection = config['mcpServers']['braus']['args'][2]
            noted = os.path.join(root, 'noted-%d' % os.getpid())
            with open(noted, 'w') as file:
                file.write(connection)
            os.replace(noted, os.path.join(root, 'connection-%d' % call))
            def say(event):
                event['session_id'] = 's1'
                print(json.dumps(event), flush=True)
            say({'type': 'system', 'subtype': 'init', 'model': 'claude-sonnet-5'})
            deadline = time.time() + 60
            while not os.path.exists(os.path.join(root, 'go-%d' % call)):
                if time.time() > deadline:
                    sys.exit(1)
                time.sleep(0.01)
            spent = {'input_tokens': 90, 'output_tokens': 10}
            say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'ok'}]}})
            say({'type': 'result', 'is_error': False, 'result': 'ok', 'usage': dict(spent, iterations=[spent]),
                 'modelUsage': {'claude-sonnet-5': {'contextWindow': 1000}}})

            """
        }

        /// The connection file call `call` was given, once it started.
        func connection(of call: Int) async throws -> URL {
            let noted = root.appending(path: "connection-\(call)")
            try #require(await WorkerContextIsolationTests.until { FileManager.default.fileExists(atPath: noted.path) },
                         "call \(call) started")
            return URL(fileURLWithPath: try String(contentsOf: noted, encoding: .utf8))
        }

        /// Lets call `call` answer.
        func go(_ call: Int) throws { try Data().write(to: root.appending(path: "go-\(call)")) }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Waits, a few milliseconds at a time and for at most `seconds`, until `condition` holds.
    static func until(seconds: Int = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Braus's own bridge on one connection, as a command line's child holds it, kept open across calls and turns.
    /// The test's end of its input never raises SIGPIPE (`F_SETNOSIGPIPE`): writing to a bridge that already ended
    /// fails with an error. (The MCP client's stdio transport is the package's own, not reachable from here.)
    @MainActor
    final class Bridge {
        let process = Process(), input = Pipe(), output = Pipe()
        private var next = 0
        private var isClosed = false

        init(_ connection: URL) throws {
            let bridge = Bundle.main.bundleURL.appending(path: "Contents/Helpers/braus-bridge")
            try #require(FileManager.default.isExecutableFile(atPath: bridge.path))
            process.executableURL  = bridge
            process.arguments      = ["mcp-bridge", "--connection", connection.path]
            process.standardInput  = input
            process.standardOutput = output
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try process.run()
        }

        /// The answer to one `tools/call` on this connection, or nil when the connection gave none: closed, refused
        /// or ended. Read off the main actor, where the host answers, for at most ten seconds.
        func call(_ name: String, _ arguments: JSONValue = .object([:])) async -> JSONValue? {
            next += 1
            guard process.isRunning, let request = try? JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(Double(next)), "method": .string("tools/call"),
                "params" : .object(["name": .string(name), "arguments": arguments]),
            ])) else { return nil }
            do { try input.fileHandleForWriting.write(contentsOf: request + [10]) } catch { return nil }
            let reading = output.fileHandleForReading
            let process = self.process
            let watchdog = Task.detached { try await Task.sleep(for: .seconds(10)); process.terminate() }
            defer { watchdog.cancel() }
            let line = await Task.detached { () -> Data in
                var line = Data()
                while !line.contains(10) {
                    let chunk = reading.availableData
                    if chunk.isEmpty { break }
                    line.append(chunk)
                }
                return line
            }.value
            return try? JSONDecoder().decode(JSONValue.self, from: line)
        }

        /// Ends the bridge as a client leaving does, and waits for it; killed by its own ID after a bound. Once.
        func close() async {
            guard !isClosed else { return }
            isClosed = true
            try? input.fileHandleForWriting.close()
            if !(await WorkerContextIsolationTests.until(seconds: 5) { !self.process.isRunning }) {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
    }

    /// One `tools/call` of `name` over a new connection to `connection`, as a command line given that file would.
    static func call(_ name: String, _ arguments: JSONValue = .object([:]), over connection: URL) async throws
        -> JSONValue? {
        let bridge = try Bridge(connection)
        let answer = await bridge.call(name, arguments)
        await bridge.close()
        return answer
    }

    /// Whether the router let the call reach Braus's tools: false when it refused it, or the connection was closed
    /// or refused.
    static func admitted(_ reply: JSONValue?) -> Bool { reply?["result"].object != nil }

    /// The session ID an `open_session` answer gives, when it opened one.
    static func sessionID(_ reply: JSONValue?) -> String? {
        guard let text = reply?["result"]["content"].array?.first?["text"].string,
              let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        return answer["session"].string
    }

    final class Flag { var isSet = false }

    /// What a test started, ended however the test ends, a failed requirement included: the bridges it opened,
    /// then `end` (its host or its team, which stops a stand-in still running).
    @MainActor
    final class Started {
        private var bridges: [Bridge] = []
        private let end: () async -> Void

        init(end: @escaping () async -> Void) { self.end = end }

        func bridge(_ connection: URL) throws -> Bridge {
            let bridge = try Bridge(connection)
            bridges.append(bridge)
            return bridge
        }

        func running(_ body: @MainActor () async throws -> Void) async throws {
            do { try await body() } catch {
                await finish()
                throw error
            }
            await finish()
        }

        private func finish() async {
            for bridge in bridges { await bridge.close() }
            bridges = []
            await end()
        }
    }

    /// A desktop in place of the Seat that counts what reaches it. `open` waits for `release` while `holds`, and
    /// opens a session under a new ID when `opens`, which `close` ends.
    final class CountingSession: AutomationSessionOperating {
        private(set) var id: UUID?
        var calls: [String] = []
        var closes = 0
        var holds = false
        var opens = false
        private var gate: CheckedContinuation<Void, Never>?

        func open(application: String, window: String?) async throws -> SceneSnapshot {
            calls.append("open \(application)")
            if holds { await withCheckedContinuation { gate = $0 } }
            guard opens else { throw AutomationFailure("Nothing opens here.") }
            id = UUID()
            return SceneSnapshot(bundleID: "com.example.notes", appName: "Notes", windowTitle: "Notes",
                                 viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        }
        func observe() async throws -> SceneSnapshot {
            calls.append("observe")
            throw AutomationFailure("Nothing is open.")
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
        func close() async {
            closes += 1
            id = nil
        }

        var isHeld: Bool { gate != nil }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    static let open: JSONValue = .object(["app": .string("TextEdit")])

    // MARK: The host

    @Test("a turn's connection acts on nothing once that turn ended, nor in the next turn, whose own works; a retired session's ID acts on nothing")
    func callsAreAdmittedOnlyOnTheirOwnTurn() async throws {
        let standIn = try StandIn()
        defer { standIn.remove() }
        let session = CountingSession()
        session.opens = true
        let host = WorkerAgentHost(workingDirectory: standIn.root.appending(path: "work"),
                                   bridgeExecutable: standIn.agent, session: { session },
                                   agents: { _ in (.claude, standIn.agent) })
        func turn() -> Task<Void, any Error> {
            Task { try await host.run(prompt: "p", selection: Self.selection, sessionID: nil, role: nil) { _ in } }
        }
        func act(_ id: String) -> JSONValue { .object(["session": .string(id), "target": .string("B3")]) }
        let started = Started { try? await host.close() }
        try await started.running {

            // Turn 1: one client, kept connected; it opens a session and acts in it.
            let first = turn()
            let old = try await standIn.connection(of: 0)
            let held = try started.bridge(old)
            let oldID = try #require(Self.sessionID(await held.call("open_session", Self.open)), "opened in its turn")
            #expect(Self.admitted(await held.call("act", act(oldID))))
            #expect(session.calls == ["open TextEdit", "act"])
            try standIn.go(0)
            try await first.value
            #expect(!Self.admitted(await held.call("act", act(oldID))), "the held connection, between turns")
            #expect(!Self.admitted(try await Self.call("act", act(oldID), over: old)), "its file, between turns")
            // The context is retired, as when its worker starts a turn elsewhere: the session closes, its ID with it.
            await host.retire()
            #expect(session.id == nil && session.calls.count == 2)

            // Turn 2: the held client and the old file act on nothing; a new client works, under a new session ID.
            let second = turn()
            let new = try await standIn.connection(of: 1)
            #expect(new != old, "the turn has a connection of its own")
            #expect(!Self.admitted(await held.call("act", act(oldID))), "the held connection, in the next turn")
            #expect(!Self.admitted(try await Self.call("act", act(oldID), over: old)), "its file, in the next turn")
            let client = try started.bridge(new)
            let stale = await client.call("act", act(oldID))
            #expect(Self.admitted(stale) && stale?["result"]["isError"] == .bool(true),
                    "the old ID is refused by the tools")
            #expect(session.calls.count == 2, "nothing reached the desktop for the old connection or the old ID")
            let newID = try #require(Self.sessionID(await client.call("open_session", Self.open)))
            #expect(newID != oldID)
            #expect(Self.admitted(await client.call("act", act(newID))))
            #expect(session.calls == ["open TextEdit", "act", "open TextEdit", "act"])
            try standIn.go(1)
            try await second.value
        }
    }

    @Test("Stop while a call waits: the turn ends only once that call finished, and nothing is run again or admitted after")
    func stopDrainsWithoutReplay() async throws {
        let standIn = try StandIn()
        defer { standIn.remove() }
        let session = CountingSession()
        session.holds = true
        let host = WorkerAgentHost(workingDirectory: standIn.root.appending(path: "work"),
                                   bridgeExecutable: standIn.agent, session: { session },
                                   agents: { _ in (.claude, standIn.agent) })
        let started = Started {
            session.release()
            try? await host.close()
        }
        try await started.running {
            let ended = Flag()
            let turn = Task {
                defer { ended.isSet = true }
                try await host.run(prompt: "p", selection: Self.selection, sessionID: nil, role: nil) { _ in }
            }
            let connection = try await standIn.connection(of: 0)
            let waiting = Task { try await Self.call("open_session", Self.open, over: connection) }
            try #require(await Self.until { session.isHeld }, "the call reached the desktop and waits")
            host.stop()
            try await Task.sleep(for: .milliseconds(300))
            #expect(!ended.isSet, "the stopped turn waits for the call in flight")
            let observed = try await Self.call("observe", .object(["session": .string("x")]), over: connection)
            #expect(!Self.admitted(observed), "no new call is admitted once stopped")
            session.release()
            await #expect(throws: CancellationError.self) { try await turn.value }
            let answered = try await waiting.value
            #expect(Self.admitted(answered), "the call in flight finished: \(String(describing: answered))")
            #expect(session.calls == ["open TextEdit"], "nothing was run again")
            #expect(session.closes >= 1, "the session closed with the stopped turn")
            #expect(!Self.admitted(try await Self.call("open_session", Self.open, over: connection)))
            #expect(session.calls.count == 1)
        }
    }

    // MARK: The team

    @Test("A→B→A: one desktop for the worker, each conversation its own host, and the context left admits nothing")
    func aToBToA() async throws {
        let standIn = try StandIn()
        let suite = "braus-contexts-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            standIn.remove()
        }
        let store = try WorkspaceStore.opening(in: standIn.root.appending(path: "store"))
        let atlas = try await store.createWorker(name: "Atlas", appearance: TemporaryStore.appearance()).id
        try await store.configure(worker: atlas, selection: Self.selection)
        let first  = try await store.createConversation(kind: .direct, participants: [atlas]).id
        let second = try await store.createConversation(kind: .direct, participants: [atlas]).id
        let team = TeamModel(store: store, connections: ModelSettingsStore(), broker: SeatBroker(),
                             agents: { _ in (.claude, standIn.agent) }, bridgeExecutable: standIn.agent,
                             preferences: preferences)
        await team.load()
        let started = Started { await team.closeAgentHosts() }
        try await started.running {

            /// Posts in `conversation`, waits for its call `call` to start, and gives its connection file.
            @MainActor func turn(_ call: Int, in conversation: UUID) async throws -> URL {
                try await team.post("message \(call)", quote: nil, in: conversation, by: atlas)
                return try await standIn.connection(of: call)
            }
            @MainActor func end(_ call: Int) async throws {
                try standIn.go(call)
                let ended = await Self.until { !team.isAnswering(atlas) }
                try #require(ended, "turn \(call) ended")
            }

            let a1 = try await turn(0, in: first)
            let contextA = try #require(team.agentContext(of: first))
            #expect(team.activeContext(of: atlas) == first)
            #expect(contextA.desktop === team.desktopSession(of: atlas))
            let heldA = try started.bridge(a1)
            #expect(Self.admitted(await heldA.call("status")), "A's connection in A's turn")
            try await end(0)

            let b = try await turn(1, in: second)
            let contextB = try #require(team.agentContext(of: second))
            #expect(team.activeContext(of: atlas) == second)
            #expect(contextB.host !== contextA.host, "each conversation its own host")
            #expect(contextB.desktop === contextA.desktop && contextB.desktop === team.desktopSession(of: atlas),
                    "the worker's one desktop")
            #expect(!Self.admitted(await heldA.call("status")), "A's held connection acts on nothing in B's turn")
            #expect(!Self.admitted(try await Self.call("status", over: a1)), "nor does A's file")
            #expect(Self.admitted(try await Self.call("status", over: b)), "B's own is admitted")
            try await end(1)

            let a2 = try await turn(2, in: first)
            let again = try #require(team.agentContext(of: first))
            #expect(team.activeContext(of: atlas) == first)
            #expect(again.host === contextA.host && again.desktop === contextA.desktop, "A resumes on its own host")
            #expect(a2 != a1, "A's new turn has a connection of its own")
            #expect(!Self.admitted(await heldA.call("status")),
                    "A's earlier connection acts on nothing in A's new turn")
            #expect(!Self.admitted(try await Self.call("status", over: a1)))
            #expect(!Self.admitted(try await Self.call("status", over: b)),
                    "B's connection acts on nothing in A's turn")
            #expect(Self.admitted(try await Self.call("status", over: a2)))
            try await end(2)
            #expect(!Self.admitted(try await Self.call("status", over: a2)), "nothing between turns")
        }
    }
}
