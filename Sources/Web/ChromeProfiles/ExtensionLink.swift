//
//  ExtensionLink.swift
//  Braus
//

import Foundation
import Synchronization
import WebDriver

/// ExtensionLink is one connection from the Braus extension's native host, that is from one extension
/// instance in one Chrome profile, over the hub's Unix socket: one JSON object per line each way.
///
/// It owns the socket. A reader thread hands every line to `receive`, and alone closes the descriptor when
/// the connection ends, so no other thread can find its number reused; `close()` only shuts the socket down.
/// `ended` is called once, from the reader thread.
final class ExtensionLink: Sendable {

    private let descriptor: Int32
    private let writing   = Mutex(())
    private let isClosed  = Mutex(false)
    /// The instance its `hello` named; nil before it.
    let instanceID = Mutex<String?>(nil)

    init(descriptor: Int32, receive: @escaping @Sendable (ExtensionLink, JSONValue) -> Void,
         ended: @escaping @Sendable (ExtensionLink) -> Void) {
        self.descriptor = descriptor
        // A write after the host died must fail, not raise SIGPIPE and end Braus.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let thread = Thread { [self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    if let message = try? JSONDecoder().decode(JSONValue.self, from: line) {
                        receive(self, message)
                    }
                }
            }
            // Under the writing lock, so no write can reach the descriptor once it is closed.
            writing.withLock { _ in
                isClosed.withLock { $0 = true }
                Darwin.close(descriptor)
            }
            ended(self)
        }
        thread.name = "dev.forte.braus.chrome-profiles.link"
        thread.start()
    }

    /// Writes one message as a line. Throws `notRunning` when the link is closed or the write fails.
    func send(_ message: JSONValue) throws {
        var line = try JSONEncoder().encode(message)
        line.append(0x0A)
        try writing.withLock { _ in
            guard !isClosed.withLock({ $0 }) else { throw ChromeProfileError.notRunning }
            try line.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, base + offset, bytes.count - offset)
                    if written <= 0 { throw ChromeProfileError.notRunning }
                    offset += written
                }
            }
        }
    }

    /// Shuts the socket down; the reader thread then closes it and ends the link. Idempotent.
    func close() {
        let wasClosed = isClosed.withLock { closed in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        shutdown(descriptor, SHUT_RDWR)
    }
}
