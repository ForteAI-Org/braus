//
//  WebPage.swift
//  Braus
//

import Foundation

/// WebPage is one tab reached through a flattened DevTools session: commands sent through it
/// carry its session, and `events()` yields only its events.
///
/// It is a handle, not an owner: copying it shares the tab, and `close()` closes the tab for
/// every copy.
public struct WebPage: Sendable, Hashable {

    public let connection: CDPConnection
    public let targetID  : String
    public let sessionID : String

    public init(connection: CDPConnection, targetID: String, sessionID: String) {
        self.connection = connection
        self.targetID   = targetID
        self.sessionID  = sessionID
    }

    public static func == (lhs: WebPage, rhs: WebPage) -> Bool {
        lhs.connection === rhs.connection && lhs.sessionID == rhs.sessionID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(connection))
        hasher.combine(sessionID)
    }

    /// Sends one command in this page's session. Errors as `CDPConnection.send`.
    public func send(
        _ method      : String,
        _ params      : JSONValue = [:],
        timeoutSeconds: Double?   = nil
    ) async throws -> JSONValue {
        try await connection.send(method, params, sessionID: sessionID, timeoutSeconds: timeoutSeconds)
    }

    /// This page's events from now on. Subscribe before the command whose event you wait for.
    public func events() async -> AsyncFilterSequence<AsyncStream<CDPEvent>> {
        let sessionID = self.sessionID
        return await connection.events().filter { $0.sessionID == sessionID }
    }

    /// Calls `observer` with each event of this page's session from now on, inline in the connection's read order
    /// (`CDPConnection.addObserver`), and with nil once the connection closed or the page's session was detached, its
    /// tab closed. Returns the key `stopObserving` takes.
    public func observe(_ observer: @escaping @Sendable (CDPEvent?) -> Void) async -> UUID {
        let sessionID = self.sessionID
        return await connection.addObserver { event in
            guard let event else { return observer(nil) }
            if event.sessionID == sessionID {
                observer(event)
            } else if event.method == "Target.detachedFromTarget", event.params["sessionId"]?.stringValue == sessionID {
                observer(nil)
            }
        }
    }

    /// Stops the observer `key`: once this returns, it is never called again.
    public func stopObserving(_ key: UUID) async {
        await connection.removeObserver(key)
    }

    /// Loads `url` and waits for its load event.
    ///
    /// Throws `CDPError.protocolError` with Chrome's `errorText` when the navigation fails, and
    /// `timedOut` when the load does not finish within `timeoutSeconds`; the page then keeps
    /// loading. A same-document navigation returns at once, since it fires no load event.
    public func navigate(to url: String, timeoutSeconds: Double = 30) async throws {
        _ = try await send("Page.enable")
        let events = await self.events()
        let answer = try await send("Page.navigate", ["url": .string(url)])
        if let errorText = answer["errorText"]?.stringValue, !errorText.isEmpty {
            throw CDPError.protocolError(method: "Page.navigate", code: 0, message: errorText)
        }
        guard answer["loaderId"] != nil else { return }
        try await Self.first(of: events, named: "Page.loadEventFired", method: "Page.navigate", within: timeoutSeconds)
    }

    /// Evaluates a script in the page's main world and returns its value by value, awaiting a
    /// returned promise. The page's own scripts can change what it reads there; a script that must not
    /// trust them runs in a `WebWorld` (`evaluate(_:in:timeoutSeconds:)`).
    ///
    /// Throws `CDPError.scriptFailed` with the exception's description when the script throws.
    public func evaluate(_ expression: String, timeoutSeconds: Double? = nil) async throws -> JSONValue {
        let answer = try await send(
            "Runtime.evaluate",
            ["expression": .string(expression), "returnByValue": true, "awaitPromise": true],
            timeoutSeconds: timeoutSeconds
        )
        if let exception = answer["exceptionDetails"] {
            let detail = exception["exception"]?["description"]?.stringValue
                ?? exception["text"]?.stringValue
                ?? "exception"
            throw CDPError.scriptFailed(detail)
        }
        return answer["result"]?["value"] ?? .null
    }

    /// Closes the tab. Its session ends with it.
    public func close() async throws {
        _ = try await connection.send("Target.closeTarget", ["targetId": .string(targetID)])
    }

    private static func first(
        of events: AsyncFilterSequence<AsyncStream<CDPEvent>>,
        named name: String,
        method    : String,
        within seconds: Double
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events where event.method == name { return }
                throw CDPError.connectionClosed(method: method)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CDPError.timedOut(method: method, seconds: seconds)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
