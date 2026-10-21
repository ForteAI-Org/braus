//
//  ExternalMCPReconnectAppTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import Darwin
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing
@testable import Braus

/// I04-A in the app: an external client reconnecting through the app's own composition, `MCPConnectionsModel` with a
/// factory shaped as `AppModel.mcp` (one session per connection, `ExternalMCPSession` over it, closed with the
/// connection) and the bridge the app bundles, `Contents/Helpers/braus-bridge`, which this test starts as each
/// client. The desktop is a session double per connection, not open until `open_session`; no Seat, capture or input.
///
/// The oracles: the instructions a client reads say a reconnect starts a fresh session; a client that goes leaves its
/// call in flight cancelled and answered nowhere and its session closed; the next client's old session ID reaches no
/// session; the new one does only what it is asked; revoking the profile ends the idle bridge with its disconnection,
/// and it does not reconnect. Every wait has a deadline; the bridges are stopped only by the PIDs this test started.
@MainActor
@Suite("A reconnected external client through the app's composition (I04-A)", .serialized, .timeLimit(.minutes(2)))
struct ExternalMCPReconnectAppTests {

    nonisolated static let application = "Synthetic Mixer"
    nonisolated static let patience: Duration = .seconds(10)

    static func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + patience
        while !condition() {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    static func isError(_ result: JSONValue) -> Bool { result["isError"] == .bool(true) }

    static func message(_ result: JSONValue) -> String {
        guard let text = result["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return "" }
        return value["message"].string ?? ""
    }

    @Test("I04-A: through the app's MCP connections and its bundled bridge, a reconnected client's old session ID reaches nothing, the call in flight is not replayed, and revocation ends the idle bridge")
    func reconnectThroughTheApp() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-i04a-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previous) }
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/braus-bridge")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "no bundled bridge")

        var desktops: [ReconnectDesktop] = []
        var closed = 0
        let model = MCPConnectionsModel(directory: root.appending(path: "MCP", directoryHint: .isDirectory),
                                        executable: executable) { profile, activity in
            // As `AppModel.mcp`: a session of its own for each connection.
            let desktop = ReconnectDesktop()
            desktops.append(desktop)
            let session = ExternalMCPSession(profile: profile, session: desktop, activity: activity)
            return MCPHostSession(router: session.router) {
                await session.close()
                closed += 1
            }
        }
        var clients: [AppBridgeClient] = []
        do {
            await model.prepare()
            let profile = MCPClientProfile(name: "I04-A")
            model.add(profile)
            await model.waitForIdle()
            model.setEnabled(true, for: profile.id)
            await model.waitForIdle()
            try #require(model.clients.first?.isListening == true, "the profile's host is not listening")
            let connection = model.configuration(for: profile.id).connection
            func started() throws -> AppBridgeClient {
                let client = try AppBridgeClient(executable: executable, connection: connection, root: root,
                                                 index: clients.count + 1)
                clients.append(client)
                return client
            }
            let open: [String: JSONValue] = ["app": .string(Self.application)]

            // Client 1: the instructions name the reconnect; it opens, acts, holds an action, and its input ends.
            let first = try started()
            let instructions = try await first.initialize()
            let reconnect = "Reconnects start a fresh session and do not restore the previous session ID"
            #expect(instructions.contains(reconnect), "\(instructions)")
            #expect(!Self.isError(try await first.call("open_session", open)))
            let old = try #require(desktops.first?.id).uuidString
            #expect(!Self.isError(try await first.call("act", ["session": .string(old), "target": .string("Create")])))
            let held = try first.send("tools/call", .object([
                "name": .string("act"), "arguments": .object(["session": .string(old), "target": .string("Slow")]),
            ]))
            try #require(try await Self.eventually { desktops.first?.calls.contains("Slow") == true },
                         "the held action never started")
            try first.closeInput()
            let firstEnding = try #require(try await first.ending(), "client 1's bridge did not exit: \(first.errors)")
            #expect(firstEnding == .exited(0), "\(firstEnding): \(first.errors)")
            try #require(try await Self.eventually { closed == 1 }, "the app never closed session 1")
            let firstCalls = desktops[0].calls
            #expect(firstCalls == ["open", "Create", "Slow", "close"], "\(firstCalls)")
            #expect(desktops[0].cancelled == ["Slow"])
            #expect(first.answer(held) == nil, "the held action was answered after its client went")

            // Client 2: a new session, not open; the old ID reaches nothing; its own session does what it asks.
            let second = try started()
            _ = try await second.initialize()
            try #require(desktops.count == 2, "\(desktops.count) sessions")
            #expect(desktops[1].id == nil, "a new connection's session is not open")
            for target in ["Create", "Slow"] {
                let stale = try await second.call("act", ["session": .string(old), "target": .string(target)])
                #expect(Self.isError(stale) && Self.message(stale).contains("stale"), "\(stale)")
            }
            #expect(desktops[1].calls == [], "the old ID reached the new session")
            #expect(desktops[0].calls == firstCalls, "the closed session was reached")
            #expect(!Self.isError(try await second.call("open_session", open)))
            let new = try #require(desktops[1].id).uuidString
            #expect(new != old)
            #expect(!Self.isError(try await second.call("act", ["session": .string(new), "target": .string("Create")])))
            #expect(desktops[1].calls == ["open", "Create"], "nothing replayed on the new session")

            // Revoking the profile ends the idle bridge with its disconnection; nothing reconnects.
            model.revoke(profile.id)
            await model.waitForIdle()
            let secondEnding = try #require(try await second.ending(), "client 2's bridge did not exit on revocation")
            #expect(secondEnding == .exited(1), "\(secondEnding): \(second.errors)")
            #expect(second.errors.contains("disconnected"), "\(second.errors)")
            try #require(try await Self.eventually { closed == 2 }, "the app never closed session 2")
            #expect(desktops[1].calls == ["open", "Create", "close"])
            #expect(desktops.count == 2, "a bridge reconnected")
        } catch {
            for client in clients { _ = await client.stop() }
            await model.shutdown()
            throw error
        }
        for client in clients {
            let stopped = await client.stop()
            if stopped {
                Issue.record("client \(client.index) (pid \(client.pid)) outlived its deadline; stopped by its PID")
            }
        }
        await model.shutdown()
    }
}

/// A connection's desktop: not open until `open_session`, a new ID at each open, a record of each call, and `Slow`
/// held until the call is cancelled.
@MainActor
private final class ReconnectDesktop: AutomationSessionOperating {
    private(set) var id: UUID?
    private(set) var calls: [String] = []
    private(set) var cancelled: [String] = []
    private let scene = SceneSnapshot(bundleID: "test.mcp", appName: "Synthetic Mixer", windowTitle: "Mixer",
                                      viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot { scene }

    func act(target: String, verb: ActionVerb, section: String?,
             desiredState: ControlState?) async throws -> ActOutcome {
        calls.append(target)
        if target == "Slow" {
            do { try await Task.sleep(for: .seconds(30)) } catch {
                cancelled.append(target)
                throw error
            }
        }
        return ActOutcome(.foundActed, "synthetic result", scene: scene)
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        calls.append("select")
        return ActOutcome(.foundActed, "synthetic selection", scene: scene)
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        calls.append("deliver")
        return ActOutcome(.foundActed, "synthetic input", scene: scene)
    }

    func applications(matching query: String?) async throws -> [ApplicationCandidate] { [] }

    func close() async {
        calls.append("close")
        id = nil
    }
}

/// A client this test started: the bundled bridge as a child process with a home of its own, its PID, its input, and
/// the lines it wrote out and to standard error.
@MainActor
final class AppBridgeClient {

    enum Ending: Equatable {
        case exited(Int32)
        case signalled(Int32)
    }

    let index: Int
    let pid: pid_t
    private let process: Process
    private let input: FileHandle
    private let output = PipeLines()
    private let diagnostics = PipeLines()
    private var inputClosed = false
    private var requestID = 0

    init(executable: URL, connection: URL, root: URL, index: Int) throws {
        let home = root.appending(path: "client-\(index)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp-bridge", "--connection", connection.path]
        process.environment = ["HOME": home.path, "TMPDIR": home.path + "/", "PATH": "/usr/bin:/bin",
                               "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        self.index = index
        self.process = process
        self.pid = process.processIdentifier
        self.input = stdin.fileHandleForWriting
        output.follow(stdout.fileHandleForReading)
        diagnostics.follow(stderr.fileHandleForReading)
    }

    var errors: String { diagnostics.text }

    func send(_ method: String, _ params: JSONValue = .object([:])) throws -> Int {
        requestID += 1
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(requestID)), "method": .string(method), "params": params,
        ])
        var data = try JSONEncoder().encode(request)
        data.append(10)
        try input.write(contentsOf: data)
        return requestID
    }

    func answer(_ id: Int) -> JSONValue? {
        output.lines.lazy
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .first { $0["id"] == .number(Double(id)) }
    }

    func ask(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = try send(method, params)
        var found: JSONValue?
        _ = try await ExternalMCPReconnectAppTests.eventually {
            found = answer(id)
            return found != nil
        }
        return try #require(found, "no answer to \(method) from client \(index): \(errors)")
    }

    /// Initializes; the instructions the client reads.
    func initialize() async throws -> String {
        let hello = try await ask("initialize", .object(["protocolVersion": .string("2025-11-25")]))
        #expect(hello["result"]["serverInfo"]["name"] == .string("braus"), "\(hello)")
        return hello["result"]["instructions"].string ?? ""
    }

    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let answer = try await ask("tools/call", .object(["name": .string(name), "arguments": .object(arguments)]))
        #expect(answer["error"] == .null, "\(answer)")
        return answer["result"]
    }

    func closeInput() throws {
        guard !inputClosed else { return }
        inputClosed = true
        try input.close()
    }

    /// How the bridge ended, once it did and both its pipes reached their end, within `patience`; nil before.
    func ending() async throws -> Ending? {
        guard try await ExternalMCPReconnectAppTests.eventually({
            !process.isRunning && output.finished && diagnostics.finished
        }) else { return nil }
        return process.terminationReason == .uncaughtSignal
            ? .signalled(process.terminationStatus) : .exited(process.terminationStatus)
    }

    func terminate(with number: Int32) {
        guard process.isRunning, pid > 0 else { return }
        Darwin.kill(pid, number)
    }

    /// Stops the bridge if it still runs, by its PID: SIGTERM, then SIGKILL after 5 s. Whether it had to.
    func stop() async -> Bool {
        defer { try? closeInput() }
        guard process.isRunning else { return false }
        for number in [SIGTERM, SIGKILL] where process.isRunning {
            terminate(with: number)
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return true
    }
}

/// The lines a pipe carries, read as they come on the pipe's own queue.
nonisolated final class PipeLines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var complete: [String] = []
    private var ended = false

    func follow(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            lock.withLock {
                if data.isEmpty { ended = true }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    complete.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
        }
    }

    var lines: [String] { lock.withLock { complete } }

    var finished: Bool { lock.withLock { ended } }

    var text: String {
        lock.withLock { (complete + [String(decoding: pending, as: UTF8.self)]).joined(separator: "\n") }
    }
}
