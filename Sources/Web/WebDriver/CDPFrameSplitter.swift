//
//  CDPFrameSplitter.swift
//  Braus
//

import Foundation

/// CDPFrameSplitter cuts the byte stream of a `--remote-debugging-pipe` connection into
/// messages: Chrome ends every JSON message with one NUL byte.
///
/// Bytes after the last NUL stay buffered until a later chunk completes the message, so a
/// message split across reads is returned whole and exactly once.
struct CDPFrameSplitter {

    private var pending = Data()

    /// Appends one chunk read from the pipe and returns the messages it completes, in order,
    /// without their terminators. Empty frames are dropped.
    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var frames: [Data] = []
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: 0) {
            if end > start { frames.append(Data(pending[start..<end])) }
            start = pending.index(after: end)
        }
        pending = Data(pending[start...])
        return frames
    }

    /// The count of buffered bytes that do not yet form a message.
    var pendingByteCount: Int { pending.count }
}
