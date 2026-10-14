//
//  CDPTransporting.swift
//  Braus
//

import Foundation

/// CDPTransporting carries DevTools messages between a `CDPConnection` and a browser: the pipe
/// of a Chrome this process started, or a double in a test.
///
/// The connection is the only caller and calls `send` from its own actor, one message at a time,
/// so a conformer needs no ordering of its own between writes.
public protocol CDPTransporting: Sendable {

    /// The bytes the browser writes, in chunks as read. A chunk may hold part of a message or
    /// several; the stream finishes when the browser closes its end. It has one consumer.
    var incoming: AsyncStream<Data> { get }

    /// Writes one complete JSON message; the transport adds the frame terminator.
    ///
    /// Throws when the browser's end is closed. A message that throws was not delivered whole.
    func send(_ message: Data) throws

    /// Closes both directions. Idempotent; `incoming` finishes after it.
    func close()
}
