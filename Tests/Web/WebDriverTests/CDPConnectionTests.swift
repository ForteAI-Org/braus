//
//  CDPConnectionTests.swift
//  Braus
//

import Foundation
import Synchronization
import Testing
@testable import WebDriver

/// The protocol layer over a scripted transport: framing, answers matched by id, errors, events
/// by session, deadlines, cancellation and a transport that closes. No Chrome.
@Suite("CDP connection")
struct CDPConnectionTests {

    // MARK: Doubles

    /// A transport that records every message and answers through `reply`, which returns the
    /// bytes Chrome would write back (already framed), or nil to stay silent.
    final class ScriptedTransport: CDPTransporting {
        let incoming: AsyncStream<Data>
        private let feed : AsyncStream<Data>.Continuation
        private let reply: @Sendable (JSONValue) -> Data?
        private let state = Mutex<(sent: [JSONValue], closed: Bool)>(([], false))

        init(reply: @escaping @Sendable (JSONValue) -> Data? = { _ in nil }) {
            (incoming, feed) = AsyncStream<Data>.makeStream()
            self.reply = reply
        }

        var sent: [JSONValue] { state.withLock { $0.sent } }

        func send(_ message: Data) throws {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: message)
            let closed  = state.withLock { state in
                if !state.closed { state.sent.append(decoded) }
                return state.closed
            }
            if closed { throw CDPError.connectionClosed(method: decoded["method"]?.stringValue ?? "") }
            if let bytes = reply(decoded) { feed.yield(bytes) }
        }

        func push(_ bytes: Data) { feed.yield(bytes) }

        func close() {
            state.withLock { $0.closed = true }
            feed.finish()
        }
    }

    static func frame(_ value: JSONValue) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0)
        return data
    }

    // MARK: Framing

    @Test("A message split across reads arrives whole, once")
    func splitAcrossChunks() {
        var splitter = CDPFrameSplitter()
        #expect(splitter.append(Data("{\"id\":".utf8)).isEmpty)
        let frames = splitter.append(Data("1}\0{\"id\":2}\0{\"i".utf8))
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["{\"id\":1}", "{\"id\":2}"])
        #expect(splitter.pendingByteCount == 3)
        #expect(splitter.append(Data("\0\0".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"i"])
        #expect(splitter.pendingByteCount == 0)
    }

    @Test("JSON values round trip through the protocol's encoding")
    func jsonRoundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": "d"]]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(decoded["a"]?[0]?.intValue == 1)
        #expect(decoded["a"]?[1]?.intValue == nil)
        #expect(decoded["b"]?["c"]?.stringValue == "d")
    }

    // MARK: Commands

    @Test("Answers reach the command with their id, and the session travels with the command")
    func answersMatchIDs() async throws {
        let transport = ScriptedTransport { message in
            let id = message["id"] ?? nil
            return Self.frame(["id": id, "result": ["echo": message["method"] ?? nil]])
        }
        let connection = await CDPConnection(transport: transport)
        let first  = try await connection.send("A.one")
        let second = try await connection.send("B.two", ["x": 1], sessionID: "S1")
        #expect(first["echo"]?.stringValue == "A.one")
        #expect(second["echo"]?.stringValue == "B.two")
        #expect(transport.sent[1]["sessionId"]?.stringValue == "S1")
        #expect(transport.sent[1]["params"]?["x"]?.intValue == 1)
        #expect(transport.sent[0]["id"]?.intValue != transport.sent[1]["id"]?.intValue)
    }

    @Test("A protocol error is thrown with Chrome's code and message")
    func protocolError() async throws {
        let transport = ScriptedTransport { message in
            Self.frame(["id": message["id"] ?? nil, "error": ["code": -32601, "message": "not found"]])
        }
        let connection = await CDPConnection(transport: transport)
        await #expect(throws: CDPError.protocolError(method: "X.y", code: -32601, message: "not found")) {
            try await connection.send("X.y")
        }
    }

    @Test("A command with no answer times out and is not sent again")
    func timeout() async throws {
        let transport  = ScriptedTransport()
        let connection = await CDPConnection(transport: transport)
        await #expect(throws: CDPError.timedOut(method: "Slow.call", seconds: 0.05)) {
            try await connection.send("Slow.call", timeoutSeconds: 0.05)
        }
        #expect(transport.sent.count == 1)
    }

    @Test("Closing the transport fails waiting commands and refuses new ones")
    func closeFailsWaiting() async throws {
        let transport  = ScriptedTransport()
        let connection = await CDPConnection(transport: transport)
        let waiting = Task { try await connection.send("Never.answered", timeoutSeconds: 10) }
        try await Task.sleep(for: .milliseconds(20))
        transport.close()
        await #expect(throws: CDPError.connectionClosed(method: "Never.answered")) { try await waiting.value }
        await #expect(throws: CDPError.connectionClosed(method: "After.close")) {
            try await connection.send("After.close")
        }
        #expect(await connection.isClosed)
    }

    @Test("Cancelling the caller ends its wait with CancellationError")
    func cancellation() async throws {
        let transport  = ScriptedTransport()
        let connection = await CDPConnection(transport: transport)
        let task = Task { try await connection.send("Long.call", timeoutSeconds: 10) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Events

    @Test("Events reach every subscriber with their session; unreadable frames are counted")
    func events() async throws {
        let transport  = ScriptedTransport()
        let connection = await CDPConnection(transport: transport)
        let stream = await connection.events()
        transport.push(Data("not json\0".utf8))
        transport.push(Self.frame(["method": "Page.loadEventFired", "params": ["timestamp": 1], "sessionId": "S1"]))
        transport.push(Self.frame(["method": "Target.targetCreated"]))
        var iterator = stream.makeAsyncIterator()
        let first  = await iterator.next()
        let second = await iterator.next()
        #expect(first == CDPEvent(method: "Page.loadEventFired", params: ["timestamp": 1], sessionID: "S1"))
        #expect(second == CDPEvent(method: "Target.targetCreated", params: [:], sessionID: nil))
        #expect(await connection.unreadableFrameCount == 1)
        transport.close()
        #expect(await iterator.next() == nil)
    }

    @Test("An observer sees an event before the answer Chrome sent after it resumes its command; once removed it sees nothing; a close reaches it as nil")
    func observersInOrder() async throws {
        // Each command is answered by an event first, then its answer, in one write, as Chrome may.
        let transport = ScriptedTransport { message in
            guard let id = message["id"] else { return nil }
            var bytes = CDPConnectionTests.frame(["method": "Network.requestWillBeSent", "sessionId": "s1",
                                                  "params": ["requestId": .string("r\(id.intValue ?? 0)")]])
            bytes.append(CDPConnectionTests.frame(["id": id, "result": [:]]))
            return bytes
        }
        let connection = await CDPConnection(transport: transport)
        let seen = Mutex<[String?]>([])
        let key = await connection.addObserver { event in
            seen.withLock { $0.append(event.map { $0.params["requestId"]?.stringValue ?? $0.method }) }
        }
        _ = try await connection.send("Runtime.evaluate", sessionID: "s1")
        #expect(seen.withLock { $0 } == ["r1"], "the event was observed before the answer resumed the command")
        #expect(await connection.observerCount == 1)

        await connection.removeObserver(key)
        _ = try await connection.send("Runtime.evaluate", sessionID: "s1")
        #expect(seen.withLock { $0 } == ["r1"], "nothing after the removal")
        #expect(await connection.observerCount == 0)

        let closing = Mutex<[Bool]>([])
        _ = await connection.addObserver { event in closing.withLock { $0.append(event == nil) } }
        transport.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(closing.withLock { $0 } == [true], "the close reached the observer as nil")
        #expect(await connection.observerCount == 0)
        let late = Mutex<[Bool]>([])
        _ = await connection.addObserver { event in late.withLock { $0.append(event == nil) } }
        #expect(late.withLock { $0 } == [true], "an observer added after the close hears nil at once")
    }

    // MARK: Launch options

    @Test("Launch arguments open the pipe on the chosen profile, headless by default")
    func launchArguments() {
        let options = ChromeLaunchOptions(userDataDirectory: URL(fileURLWithPath: "/tmp/braus profile"))
        #expect(options.arguments.contains("--remote-debugging-pipe"))
        #expect(options.arguments.contains("--user-data-dir=/tmp/braus profile"))
        #expect(options.arguments.contains("--headless"))
        #expect(options.arguments.last == "about:blank")
        var headed = options
        headed.isHeadless = false
        #expect(!headed.arguments.contains("--headless"))
        // A visible Chrome starts with no window, so the one Braus opens later stays in the background.
        #expect(headed.arguments.contains("--no-startup-window") && !headed.arguments.contains("about:blank"))
        let profile = ChromeLaunchOptions.brausProfile(applicationSupport: URL(fileURLWithPath: "/Lib/AS"))
        #expect(profile.path(percentEncoded: false).hasSuffix("/Lib/AS/Braus/chrome-web/"))
    }
}
