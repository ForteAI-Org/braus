//
//  CommandGate.swift
//  Braus
//

import Synchronization

/// CommandGate admits a browser's new commands until it is closed: once `close` returned, no command it admits
/// starts, and one it admitted before has gone out whole. Closing what the browser opened is not a new command and
/// does not pass through it.
///
/// A web session on a paired Chrome profile gives one to the profile's transport and closes it when the
/// conversation's choice of profile changes, so a call already under way sends nothing more to the profile chosen
/// before, while the tab Braus opened there can still be closed.
public final class CommandGate: Sendable {

    private let isOpenState = Mutex(true)

    public init() {}

    public var isOpen: Bool { isOpenState.withLock { $0 } }

    /// Closes the gate; it never opens again. Waits for a command being admitted to go out. Idempotent.
    public func close() {
        isOpenState.withLock { $0 = false }
    }

    /// Runs `send` while the gate is open, under its lock, so `close` waits for it; false, and `send` not run, once
    /// the gate is closed.
    public func admit(_ send: () throws -> Void) throws -> Bool {
        try isOpenState.withLock { isOpen in
            guard isOpen else { return false }
            try send()
            return true
        }
    }
}
