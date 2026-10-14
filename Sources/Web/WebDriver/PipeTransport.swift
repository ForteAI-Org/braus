//
//  PipeTransport.swift
//  Braus
//

import Foundation
import Synchronization

/// PipeTransport is `CDPTransporting` over the two pipes of `--remote-debugging-pipe`: this
/// process writes Chrome's file descriptor 3 and reads its file descriptor 4.
///
/// It owns both descriptors and closes them in `close()` or when released. Reads arrive on
/// `FileHandle`'s background queue and are handed to `incoming` without being parsed.
final class PipeTransport: CDPTransporting {

    let incoming: AsyncStream<Data>

    private let toBrowser  : FileHandle
    private let fromBrowser: FileHandle
    private let feed       : AsyncStream<Data>.Continuation
    private let isClosed   = Mutex(false)

    /// Takes ownership of both handles. The writing descriptor must not raise SIGPIPE
    /// (`F_SETNOSIGPIPE`), or a write after Chrome died would end this process.
    init(toBrowser: FileHandle, fromBrowser: FileHandle) {
        self.toBrowser   = toBrowser
        self.fromBrowser = fromBrowser
        (incoming, feed) = AsyncStream<Data>.makeStream()
        let feed = self.feed
        fromBrowser.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(chunk)
            }
        }
    }

    deinit {
        close()
    }

    func send(_ message: Data) throws {
        var framed = message
        framed.append(0)
        try toBrowser.write(contentsOf: framed)
    }

    func close() {
        let wasClosed = isClosed.withLock { closed in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        fromBrowser.readabilityHandler = nil
        feed.finish()
        // A close that fails leaves nothing to undo: the descriptor is released either way.
        try? toBrowser.close()
        try? fromBrowser.close()
    }
}
