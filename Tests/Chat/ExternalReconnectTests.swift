//
//  ExternalReconnectTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
@testable import LocalMCP
import Network
import PerceptionCore
import Testing

/// I04 through the host an external client connects to: `LocalMCPHost` with one connection at a time, each connection
/// composed as the app's factory composes it (`AppModel.mcp`): a session of its own, not open until `open_session`,
/// `AutomationTools` (its `mcp` producer left out: this session has no memory, so nothing is recorded), an
/// `MCPRouter`, and the session closed with the connection. Two clients speak over loopback with the host's token, as
/// the bridge forwards them.
///
/// The oracles: after the first client goes, the second, with the same token, gets a new session; the first one's
/// session ID reaches neither session; the call the first client had in flight was cancelled and runs nowhere again;
/// and the second session carries out only what the second client asks. The bridge process and `ExternalMCPSession`
/// itself (the app's) are not run here.
@MainActor
@Suite("A reconnected client through the host (I04)", .serialized, .timeLimit(.minutes(1)))
struct ExternalReconnectTests {

    nonisolated static let application = "Synthetic Mixer"

    private static var requestID = 0

    /// How long one wait may last: a connection, an answer, or a state the host reaches.
    nonisolated static let patience: Duration = .seconds(10)

    /// Closes `channel` after `patience` unless cancelled first: a start or a read it ends then returns.
    private static func watchdog(_ channel: MCPChannel) -> Task<Void, Never> {
        Task { @MainActor in
            guard (try? await Task.sleep(for: patience)) != nil else { return }
            channel.close()
        }
    }

    /// Waits until `condition` holds, for `patience` at most, cancellation honoured: false when it never did.
    private static func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + patience
        while !condition() {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// A channel to the host, kept in `channels` so it is closed whatever happens after.
    private func connect(_ endpoint: LocalConnection, keeping channels: inout [MCPChannel]) async throws -> MCPChannel {
        let port = try #require(NWEndpoint.Port(rawValue: endpoint.port))
        let channel = MCPChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        channels.append(channel)
        let watchdog = Self.watchdog(channel)
        defer { watchdog.cancel() }
        try await channel.start()
        return channel
    }

    private func envelope(_ endpoint: LocalConnection, _ method: String, _ params: JSONValue) -> JSONValue {
        Self.requestID += 1
        return .object(["token": .string(endpoint.token), "message": .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(Self.requestID)), "method": .string(method),
            "params": params,
        ])])
    }

    /// One request and its answer, within `patience`: past it the channel is closed and the read ends unanswered.
    private func ask(_ channel: MCPChannel, _ endpoint: LocalConnection, _ method: String,
                     _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await channel.write(envelope(endpoint, method, params))
        let watchdog = Self.watchdog(channel)
        defer { watchdog.cancel() }
        return try #require(try await channel.read(), "no answer to \(method) within \(Self.patience)")
    }

    /// One `tools/call`: its result, as the client reads it.
    private func call(_ channel: MCPChannel, _ endpoint: LocalConnection, _ name: String,
                      _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let answer = try await ask(channel, endpoint, "tools/call",
                                   .object(["name": .string(name), "arguments": .object(arguments)]))
        #expect(answer["error"] == .null, "\(answer)")
        return answer["result"]
    }

    private static func message(_ result: JSONValue) -> String {
        guard let text = result["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return "" }
        return value["message"].string ?? ""
    }

    @Test("I04: after a reconnect the old session ID reaches no session, the call in flight is not replayed, and the new session does only what it is asked")
    func oldIDAfterReconnect() async throws {
        var sessions: [HostedSession] = []
        var closed = 0
        var channels: [MCPChannel] = []
        let host = LocalMCPHost(maximumConnections: 1) {
            let session = HostedSession()
            sessions.append(session)
            let tools = AutomationTools(session: session)
            let router = MCPRouter(tools: tools.toolDefinitions) { name, arguments in
                try await tools.call(name, arguments)
            }
            return MCPHostSession(router: router) {
                await session.close()
                closed += 1
            }
        }
        // The host and every channel are closed on every path, a failed start, connection, answer or wait included.
        do {
            let endpoint = try await host.start()
            let initialize: JSONValue = .object(["protocolVersion": .string("2025-11-25")])

            // The first client opens its session, acts once, and goes while a second action is running.
            let first = try await connect(endpoint, keeping: &channels)
            let hello = try await ask(first, endpoint, "initialize", initialize)
            #expect(hello["result"]["serverInfo"]["name"] == .string("braus"), "\(hello)")
            let opened = try await call(first, endpoint, "open_session", ["app": .string(Self.application)])
            #expect(opened["isError"] == .bool(false), "\(opened)")
            let old = try #require(sessions.first?.id).uuidString
            let acted = try await call(first, endpoint, "act", ["session": .string(old), "target": .string("Create")])
            #expect(acted["isError"] == .bool(false), "\(acted)")
            try await first.write(envelope(endpoint, "tools/call", .object([
                "name": .string("act"), "arguments": .object(["session": .string(old), "target": .string("Slow")]),
            ])))
            try #require(try await Self.eventually { sessions.first?.calls.contains("Slow") == true },
                         "the held action never started")
            first.close()
            try #require(try await Self.eventually { closed == 1 }, "the host never closed the first session")
            let firstCalls = try #require(sessions.first).calls
            #expect(firstCalls == ["open", "Create", "Slow", "close"], "\(firstCalls)")
            #expect(sessions.first?.cancelled == ["Slow"], "the call in flight was cancelled with the connection")

            // The second client, with the same token, gets a new session, not yet open.
            let second = try await connect(endpoint, keeping: &channels)
            let again = try await ask(second, endpoint, "initialize", initialize)
            #expect(again["result"]["serverInfo"]["name"] == .string("braus"), "\(again)")
            #expect(sessions.count == 2)
            #expect(sessions.last?.id == nil, "a new connection's session is not open")

            // The old ID reaches nothing: refused, no gesture on either session.
            for target in ["Create", "Slow"] {
                let stale = try await call(second, endpoint, "act",
                                           ["session": .string(old), "target": .string(target)])
                #expect(stale["isError"] == .bool(true), "\(stale)")
                #expect(Self.message(stale).contains("stale"), "\(stale)")
            }
            #expect(sessions.last?.calls == [], "the old ID reached the new session")
            #expect(sessions.first?.calls == firstCalls, "the old session was reached after its close")

            // The new session does what the second client asks, and only that; its ID is not the old one.
            _ = try await call(second, endpoint, "open_session", ["app": .string(Self.application)])
            let new = try #require(sessions.last?.id).uuidString
            #expect(new != old)
            let mine = try await call(second, endpoint, "act", ["session": .string(new), "target": .string("Create")])
            #expect(mine["isError"] == .bool(false), "\(mine)")
            #expect(sessions.last?.calls == ["open", "Create"], "nothing replayed on the new session")
            #expect(sessions.first?.calls == firstCalls)
            #expect(sessions.allSatisfy { $0.calls.filter { $0 == "Slow" }.count <= 1 }, "the cancelled call ran again")
        } catch {
            for channel in channels { channel.close() }
            await host.stopAndDrain()
            throw error
        }
        await host.stopAndDrain()
        #expect(closed == 2)
        for channel in channels { channel.close() }
    }
}

/// A connection's session: not open until `open_session`, a new ID at each open, a record of each call, and `Slow`
/// held until the call is cancelled. `BridgeReconnectTests` composes its connections with it too.
@MainActor
final class HostedSession: AutomationSessionOperating {
    var id: UUID?
    var calls: [String] = []
    var cancelled: [String] = []
    let scene = SceneSnapshot(bundleID: "test.synthetic", appName: "Synthetic Mixer", windowTitle: "Synthetic",
                              viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot {
        calls.append("observe")
        return scene
    }

    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] { [] }

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

    func close() async {
        calls.append("close")
        id = nil
    }
}
