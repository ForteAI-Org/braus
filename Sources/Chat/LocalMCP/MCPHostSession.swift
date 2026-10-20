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
        guard pending.count < 32 else { throw CocoaError(.fileReadTooLarge) }
        let id = UUID()
        pending[id] = Task {
            defer { pending.removeValue(forKey: id) }
            let result = await session.router.handle(message)
            do { try await channel.write(result ?? .null) }
            catch { channel.close() }
        }
    }

    func finish() async {
        if let notificationSink { session.router.removeNotificationSink(notificationSink) }
        notificationSink = nil
        await notifying?.value
        notifying = nil
        if session.cancelsOnDisconnect { session.router.pause() }
        for task in pending.values { await task.value }
        await session.close()
    }
}
