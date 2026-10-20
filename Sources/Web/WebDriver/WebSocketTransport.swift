//
//  WebSocketTransport.swift
//  Braus
//

import Foundation
import Synchronization

/// WebSocketTransport is `CDPTransporting` over the DevTools WebSocket of a Chrome this process did not
/// start: the person's own, reached on loopback once they allowed it (`PersonalChrome`).
///
/// Each message read is handed on with the pipe's terminator, so `CDPConnection` frames both
/// transports alike. It owns its URL session and closes it in `close()` or when released.
final class WebSocketTransport: CDPTransporting {

    /// The largest message read, in bytes: a DevTools answer such as a screenshot exceeds
    /// `URLSessionWebSocketTask`'s 1 MiB default, and a message over it would end the connection.
    static let maximumMessageBytes = 256 << 20

    let incoming: AsyncStream<Data>

    private let session: URLSession
    private let task   : URLSessionWebSocketTask
    private let feed   : AsyncStream<Data>.Continuation
    private let state  = Mutex<(isClosed: Bool, failure: (any Error)?)>((false, nil))

    /// Opens the WebSocket at `url` at once and starts reading it.
    init(url: URL, maximumMessageBytes: Int = WebSocketTransport.maximumMessageBytes) {
        session = URLSession(configuration: .ephemeral)
        task    = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageBytes
        (incoming, feed) = AsyncStream<Data>.makeStream()
        task.resume()
        receiveNext()
    }

    deinit {
        close()
    }

    /// The error that ended the connection, such as a refused connection or a rejected handshake; nil while it
    /// is open and after a `close()` that nothing preceded.
    var failure: (any Error)? { state.withLock { $0.failure } }

    func send(_ message: Data) throws {
        guard !state.withLock({ $0.isClosed }) else { throw URLError(.networkConnectionLost) }
        // The task sends in the order of these calls; a failed send ends the connection, which fails what waits.
        task.send(.string(String(decoding: message, as: UTF8.self))) { [weak self] error in
            if let error { self?.end(failure: error) }
        }
    }

    func close() {
        end(failure: nil)
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
                case .success(let message):
                    var frame: Data
                    switch message {
                        case .string(let text): frame = Data(text.utf8)
                        case .data(let bytes) : frame = bytes
                        @unknown default      : frame = Data()
                    }
                    frame.append(0)
                    feed.yield(frame)
                    receiveNext()
                case .failure(let error):
                    end(failure: error)
            }
        }
    }

    /// Ends the connection once: keeps the first failure, finishes `incoming` and releases the session.
    private func end(failure: (any Error)?) {
        let wasClosed = state.withLock { state in
            defer { state.isClosed = true }
            if !state.isClosed { state.failure = failure }
            return state.isClosed
        }
        guard !wasClosed else { return }
        feed.finish()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
