//
//  CDPConnection.swift
//  Braus
//

import Foundation

/// CDPConnection speaks the Chrome DevTools Protocol over one transport: it numbers commands,
/// matches each answer to its command and hands events to every subscriber.
///
/// Sessions are flattened: a page's commands and events carry its `sessionId` on this one
/// connection. When the transport finishes, every command still waiting fails with
/// `CDPError.connectionClosed` and every event stream ends.
public actor CDPConnection {

    /// The deadline a command gets when its caller names none.
    public let commandTimeoutSeconds: Double

    /// Frames that were not JSON or carried neither an answer nor an event. They are dropped.
    public private(set) var unreadableFrameCount = 0

    /// Whether the transport has finished or `close()` was called.
    public private(set) var isClosed = false

    /// How many observers `addObserver` registered and nothing removed yet.
    public var observerCount: Int { observers.count }

    private struct Waiting {
        let method      : String
        let continuation: CheckedContinuation<JSONValue, any Error>
        var deadline    : Task<Void, Never>?
    }

    private let transport  : any CDPTransporting
    private var nextID     = 1
    private var waiting    : [Int: Waiting] = [:]
    private var subscribers: [UUID: AsyncStream<CDPEvent>.Continuation] = [:]
    private var observers  : [UUID: @Sendable (CDPEvent?) -> Void] = [:]
    private var splitter   = CDPFrameSplitter()
    private var reading    : Task<Void, Never>?

    /// Starts reading the transport at once, so no answer or event is lost.
    public init(transport: any CDPTransporting, commandTimeoutSeconds: Double = 30) async {
        self.transport             = transport
        self.commandTimeoutSeconds = commandTimeoutSeconds
        let chunks = transport.incoming
        reading = Task { [weak self] in
            for await chunk in chunks {
                await self?.receive(chunk)
            }
            await self?.finish()
        }
    }

    /// Sends one command and returns its `result`, `.object([:])` when Chrome sends none.
    ///
    /// Throws `CDPError.protocolError` when Chrome rejects it, `connectionClosed` or `timedOut`
    /// when the answer does not come, and `CancellationError` when the calling task is cancelled.
    /// In the last three cases the command may have run; it is never sent again.
    public func send(
        _ method      : String,
        _ params      : JSONValue = [:],
        sessionID     : String?   = nil,
        timeoutSeconds: Double?   = nil
    ) async throws -> JSONValue {
        guard !isClosed else { throw CDPError.connectionClosed(method: method) }
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method), "params": params]
        if let sessionID { message["sessionId"] = .string(sessionID) }
        let data    = try JSONEncoder().encode(JSONValue.object(message))
        let timeout = timeoutSeconds ?? commandTimeoutSeconds

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A cancellation that came before this point found no entry to resolve.
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                waiting[id] = Waiting(method: method, continuation: continuation, deadline: nil)
                do {
                    try transport.send(data)
                } catch {
                    resolve(id, with: .failure(CDPError.connectionClosed(method: method)))
                    return
                }
                waiting[id]?.deadline = Task { [weak self] in
                    guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
                    await self?.resolve(id, with: .failure(CDPError.timedOut(method: method, seconds: timeout)))
                }
            }
        } onCancel: {
            Task { await self.resolve(id, with: .failure(CancellationError())) }
        }
    }

    /// A stream of every event from now on, browser and page sessions alike, until the
    /// connection closes or the consumer stops iterating.
    ///
    /// Subscribe before sending the command whose event you wait for. The stream keeps the
    /// newest 4096 undelivered events and drops older ones.
    public func events() -> AsyncStream<CDPEvent> {
        let (stream, continuation) = AsyncStream<CDPEvent>.makeStream(bufferingPolicy: .bufferingNewest(4096))
        guard !isClosed else {
            continuation.finish()
            return stream
        }
        let key = UUID()
        subscribers[key] = continuation
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(key) }
        }
        return stream
    }

    /// Calls `observer` with every event from now on, inline, in the order the connection reads them, and with nil
    /// once the connection closed. An answer read after an event is resumed after the observer saw that event, so a
    /// caller that awaited a command finds every event Chrome sent before its answer already observed. The observer
    /// runs on the connection and must return at once. Returns the key `removeObserver` takes.
    public func addObserver(_ observer: @escaping @Sendable (CDPEvent?) -> Void) -> UUID {
        let key = UUID()
        guard !isClosed else {
            observer(nil)
            return key
        }
        observers[key] = observer
        return key
    }

    /// Removes the observer `key`: once this returns, it is never called again.
    public func removeObserver(_ key: UUID) {
        observers.removeValue(forKey: key)
    }

    /// Closes the transport. Waiting commands fail with `connectionClosed`.
    public func close() {
        transport.close()
        finish()
    }

    // MARK: Reading

    private func receive(_ chunk: Data) {
        for frame in splitter.append(chunk) {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: frame) else {
                unreadableFrameCount += 1
                continue
            }
            if let id = message["id"]?.intValue {
                answer(id, message)
            } else if let method = message["method"]?.stringValue {
                let event = CDPEvent(
                    method   : method,
                    params   : message["params"] ?? [:],
                    sessionID: message["sessionId"]?.stringValue
                )
                for observer in observers.values { observer(event) }
                for subscriber in subscribers.values { subscriber.yield(event) }
            } else {
                unreadableFrameCount += 1
            }
        }
    }

    private func answer(_ id: Int, _ message: JSONValue) {
        guard let method = waiting[id]?.method else { return }
        if let error = message["error"] {
            resolve(id, with: .failure(CDPError.protocolError(
                method : method,
                code   : error["code"]?.intValue ?? 0,
                message: error["message"]?.stringValue ?? ""
            )))
        } else {
            resolve(id, with: .success(message["result"] ?? [:]))
        }
    }

    /// Resumes the command once; a later answer, deadline or cancellation for it finds nothing.
    private func resolve(_ id: Int, with result: Result<JSONValue, any Error>) {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        entry.deadline?.cancel()
        entry.continuation.resume(with: result)
    }

    private func unsubscribe(_ key: UUID) {
        subscribers.removeValue(forKey: key)
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        for id in Array(waiting.keys) {
            let method = waiting[id]?.method ?? ""
            resolve(id, with: .failure(CDPError.connectionClosed(method: method)))
        }
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
        for observer in observers.values { observer(nil) }
        observers.removeAll()
    }
}
