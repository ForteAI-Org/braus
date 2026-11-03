import Foundation

/// MCPHostSession owns a router for one authenticated connection. Its close callback runs after
/// pending requests drain. A dedicated session cancels work on disconnect; an internal chat can
/// deliberately retain its router and Seat between provider connections.
@MainActor
public struct MCPHostSession {
    let router: MCPRouter
    let cancelsOnDisconnect: Bool
    let close: @MainActor () async -> Void

    public init(
        router: MCPRouter,
        cancelsOnDisconnect: Bool = true,
        close: @escaping @MainActor () async -> Void = {}
    ) {
        self.router = router
        self.cancelsOnDisconnect = cancelsOnDisconnect
        self.close = close
    }
}

/// MCPPeer drains bounded requests while continuing to read EOF and cancellation notifications.
@MainActor
final class MCPPeer {
    let channel: MCPChannel
    let session: MCPHostSession
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var requests = Set<UUID>()
    private var isReceiving = true
    private var notificationSink: UUID?
    private var notifying: Task<Void, Never>?

    init(channel: MCPChannel, session: MCPHostSession) {
        self.channel = channel
        self.session = session
        // Server-initiated notifications (a changed tool list) reach this connection, in order, until it
        // finishes; `finish` waits for those already sent.
        notificationSink = session.router.addNotificationSink { [weak self] message in
            guard let self else { return }
            let previous = notifying
            notifying = Task { [channel] in
                await previous?.value
                do { try await channel.write(message) } catch { channel.close() }
            }
        }
    }

    func receive(_ message: JSONValue) throws {
        guard isReceiving else { return }
        let id = UUID()
        let isRequest = message["id"] != .null && message["method"] != .null
        if isRequest, requests.count >= 32 {
            let response: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": message["id"],
                "error": .object([
                    "code": .number(-32000),
                    "message": .string("Too many pending requests; wait for an answer before sending more.")
                ])
            ])
            pending[id] = Task {
                defer { pending.removeValue(forKey: id) }
                do { try await channel.write(response) }
                catch { channel.close() }
            }
            return
        }
        let task = Task {
            defer {
                pending.removeValue(forKey: id)
                requests.remove(id)
            }
            if let result = await session.router.handle(message) {
                do { try await channel.write(result) }
                catch { channel.close() }
            }
        }
        pending[id] = task
        if isRequest { requests.insert(id) }
    }

    /// Stops admission without closing the channel that still carries accepted responses.
    func beginShutdown() {
        guard isReceiving else { return }
        isReceiving = false
        if let notificationSink { session.router.removeNotificationSink(notificationSink) }
        notificationSink = nil
        if session.cancelsOnDisconnect { session.router.pause() }
    }

    /// Joins response writes without waiting for the client's next input or EOF.
    func drainResponses() async {
        await notifying?.value
        notifying = nil
        for task in Array(pending.values) { await task.value }
    }

    func finish() async {
        beginShutdown()
        await drainResponses()
        await session.close()
    }
}
