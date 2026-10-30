//
//  InteractionButtonState.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Synchronization

/// InteractionButtonState shares the tap's left press with readers before gesture delivery.
/// A revision changes at either edge, so a read spanning a drag can be discarded. The optional
/// physical check observes release after listener shutdown; tests supply only explicit edges.
package final class InteractionButtonState: Sendable {
    package struct Snapshot: Sendable, Equatable {
        package let processID: Int32?
        package let revision: UInt64
    }

    private let state = Mutex(Snapshot(processID: nil, revision: 0))
    private let listening = Mutex(true)
    private let isPhysicallyPressed: (@Sendable () -> Bool)?

    package init(isPhysicallyPressed: (@Sendable () -> Bool)? = nil) {
        self.isPhysicallyPressed = isPhysicallyPressed
    }

    package func press(processID: Int32) {
        state.withLock { $0 = Snapshot(processID: processID, revision: $0.revision &+ 1) }
    }

    package func release() {
        state.withLock { $0 = Snapshot(processID: nil, revision: $0.revision &+ 1) }
    }

    package func finishListening() { listening.withLock { $0 = false } }

    package func snapshot() -> Snapshot {
        let current = state.withLock { $0 }
        if !listening.withLock({ $0 }), current.processID != nil,
           let isPhysicallyPressed, !isPhysicallyPressed() {
            return state.withLock {
                if $0 == current { $0 = Snapshot(processID: nil, revision: $0.revision &+ 1) }
                return $0
            }
        }
        return current
    }
}
