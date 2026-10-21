//
//  BridgeReconnectTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import Darwin
import Foundation
import LocalMCP
import TestScratch
import Testing

/// I04-B through the bridge process an external client runs: the test starts each client as a child,
/// `<bridge> mcp-bridge --connection <file>` (`braus-bridge`, which the app bundles, or `braus`: the same words), and
/// speaks JSONL on its standard input and output. The bridge forwards to a `LocalMCPHost` in this process, one
/// connection at a time, each composed as in `ExternalReconnectTests`: a session double of its own, not open until
/// `open_session`, `AutomationTools`, `MCPRouter`, the session closed with the connection. No Seat, desktop, account
/// or memory.
///
/// The oracles: a client that goes, by the end of its input or killed, leaves its call in flight cancelled, answered
/// nowhere, and its session closed; the next client's old session ID reaches no session; nothing runs again; a host
/// that stops ends the bridge with its disconnection, and the bridge does not reconnect.
///
/// Opt in with `BRAUS_BRIDGE_TESTS=1` and `BRAUS_TEST_BRIDGE` naming the bridge executable. Each bridge runs with a
/// fresh home and temporary folder under this test's own, and an environment of its own; one that outlives its
/// deadline is stopped only by the PID this test started it with, SIGTERM then SIGKILL. Every wait has a deadline and
/// honours cancellation; the bridges, the host and the folder are cleaned up on every path.
@MainActor
@Suite("A reconnected client through the bridge process (I04-B)", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["BRAUS_BRIDGE_TESTS"] == "1"))
struct BridgeReconnectTests {

    nonisolated static let application = "Synthetic Mixer"

    /// How long one wait may last: an answer, a state the host reaches, a bridge's exit.
    nonisolated static let patience: Duration = .seconds(10)

    /// Waits until `condition` holds, for `patience` at most, cancellation honoured: false when it never did.
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

    /// The message of a tool's failure, as `MCPRouter.failureResult` writes it.
    static func message(_ result: JSONValue) -> String {
        guard let text = result["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return "" }
        return value["message"].string ?? ""
    }

    /// Stops what still runs. On a path that completed, a bridge still running is a failure of its own.
    static func finish(_ bridges: [BridgeProcess], _ connections: HostedConnections, completed: Bool) async {
        for bridge in bridges {
            let stopped = await bridge.stop()
            if stopped && completed {
                Issue.record("bridge \(bridge.index) (pid \(bridge.pid)) outlived its deadline; stopped by its PID")
            }
        }
        await connections.host.stopAndDrain()
    }

    @Test("I04-B: through the bridge, a client that goes leaves its call cancelled and its session closed; the next one's old ID reaches nothing, nothing is replayed, and a host that stops ends the bridge")
    func reconnectThroughTheBridge() async throws {
        let named = try #require(ProcessInfo.processInfo.environment["BRAUS_TEST_BRIDGE"],
                                 "BRAUS_TEST_BRIDGE names no bridge executable")
        let executable = URL(fileURLWithPath: named)
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "\(named) is not executable")
        let root = URL.temporaryDirectory.appending(path: "braus-i04-bridge-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // A write to a bridge that already ended fails with EPIPE instead of ending this process.
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previous) }

        let connections = HostedConnections()
        var bridges: [BridgeProcess] = []
        do {
            let endpoint = try await connections.host.start()
            let connection = root.appending(path: "connection.json")
            try JSONEncoder().encode(endpoint).write(to: connection)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connection.path)
            func started() throws -> BridgeProcess {
                let bridge = try BridgeProcess(executable: executable, connection: connection, root: root,
                                               index: bridges.count + 1)
                bridges.append(bridge)
                return bridge
            }
            let open: [String: JSONValue] = ["app": .string(Self.application)]

            // Bridge 1 opens its session, acts, and holds a second action; then its client's input ends. The bridge
            // ends its connection and exits 0; the host cancels the action and closes the session.
            let first = try started()
            try await first.initialize()
            #expect(!Self.isError(try await first.call("open_session", open)))
            let old = try #require(connections.sessions.first?.id).uuidString
            #expect(!Self.isError(try await first.call("act", ["session": .string(old), "target": .string("Create")])))
            let firstHeld = try first.send("tools/call", .object([
                "name": .string("act"), "arguments": .object(["session": .string(old), "target": .string("Slow")]),
            ]))
            try #require(try await Self.eventually { connections.sessions.first?.calls.contains("Slow") == true },
                         "the held action never started")
            try first.closeInput()
            let firstEnding = try #require(try await first.ending(), "bridge 1 did not exit: \(first.errors)")
            #expect(firstEnding == .exited(0), "\(firstEnding): \(first.errors)")
            try #require(try await Self.eventually { connections.closed == 1 }, "the host never closed session 1")
            let firstCalls = connections.sessions[0].calls
            #expect(firstCalls == ["open", "Create", "Slow", "close"], "\(firstCalls)")
            #expect(connections.sessions[0].cancelled == ["Slow"])
            #expect(first.answer(firstHeld) == nil, "the held action was answered after its client went")

            // Bridge 2, the same connection file: a new session, not open. The old ID reaches nothing; its own
            // session does what it asks.
            let second = try started()
            try await second.initialize()
            try #require(connections.sessions.count == 2, "\(connections.sessions.count) sessions")
            #expect(connections.sessions[1].id == nil, "a new connection's session is not open")
            for target in ["Create", "Slow"] {
                let stale = try await second.call("act", ["session": .string(old), "target": .string(target)])
                #expect(Self.isError(stale) && Self.message(stale).contains("stale"), "\(stale)")
            }
            #expect(connections.sessions[1].calls == [], "the old ID reached the new session")
            #expect(connections.sessions[0].calls == firstCalls, "the closed session was reached")
            #expect(!Self.isError(try await second.call("open_session", open)))
            let new = try #require(connections.sessions[1].id).uuidString
            #expect(new != old)
            #expect(!Self.isError(try await second.call("act", ["session": .string(new), "target": .string("Create")])))
            #expect(connections.sessions[1].calls == ["open", "Create"], "nothing replayed on the new session")

            // Bridge 2 is killed while an action holds: the host cancels it and closes session 2.
            let secondHeld = try second.send("tools/call", .object([
                "name": .string("act"), "arguments": .object(["session": .string(new), "target": .string("Slow")]),
            ]))
            try #require(try await Self.eventually { connections.sessions[1].calls.contains("Slow") },
                         "the second held action never started")
            second.terminate(with: SIGTERM)
            let secondEnding = try #require(try await second.ending(), "bridge 2 did not end on SIGTERM")
            #expect(secondEnding == .signalled(SIGTERM), "\(secondEnding)")
            try #require(try await Self.eventually { connections.closed == 2 }, "the host never closed session 2")
            let secondCalls = connections.sessions[1].calls
            #expect(secondCalls == ["open", "Create", "Slow", "close"], "\(secondCalls)")
            #expect(connections.sessions[1].cancelled == ["Slow"])
            #expect(second.answer(secondHeld) == nil, "the held action was answered after its bridge was killed")

            // Bridge 3: bridge 2's ID reaches nothing, nothing of the closed sessions runs again; then the host
            // stops, and the bridge ends with its disconnection, exit 1, without reconnecting.
            let third = try started()
            try await third.initialize()
            try #require(connections.sessions.count == 3, "\(connections.sessions.count) sessions")
            let staleAgain = try await third.call("act", ["session": .string(new), "target": .string("Slow")])
            #expect(Self.isError(staleAgain) && Self.message(staleAgain).contains("stale"), "\(staleAgain)")
            #expect(connections.sessions[2].calls == [])
            #expect(connections.sessions[0].calls == firstCalls && connections.sessions[1].calls == secondCalls)
            await connections.host.stopAndDrain()
            let thirdEnding = try #require(try await third.ending(), "bridge 3 did not exit when the host stopped")
            #expect(thirdEnding == .exited(1), "\(thirdEnding): \(third.errors)")
            #expect(third.errors.contains("disconnected"), "\(third.errors)")
            #expect(connections.closed == 3)
            #expect(connections.sessions.count == 3, "a bridge reconnected")
        } catch {
            await Self.finish(bridges, connections, completed: false)
            throw error
        }
        await Self.finish(bridges, connections, completed: true)
    }
}

/// The host and the connections it composed: each a `HostedSession`, closed with its connection.
@MainActor
final class HostedConnections {
    var sessions: [HostedSession] = []
    var closed = 0

    lazy var host = LocalMCPHost(maximumConnections: 1) { [unowned self] in
        let session = HostedSession()
        sessions.append(session)
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        return MCPHostSession(router: router) { [unowned self] in
            await session.close()
            closed += 1
        }
    }
}

/// The checks this suite makes of a bridge's `initialize` and of each call (`BridgeProcess`, in TestScratch).
extension BridgeProcess {
    func initialize() async throws {
        let hello = try await ask("initialize", .object(["protocolVersion": .string("2025-11-25")]))
        #expect(hello["result"]["serverInfo"]["name"] == .string("braus"), "\(hello)")
    }

    /// One `tools/call`: its result.
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let answer = try await ask("tools/call", .object(["name": .string(name), "arguments": .object(arguments)]))
        #expect(answer["error"] == .null, "\(answer)")
        return answer["result"]
    }
}
