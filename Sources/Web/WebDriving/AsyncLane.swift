//
//  AsyncLane.swift
//  Braus
//

import Synchronization

/// AsyncLane runs the operations given to it one at a time, in the order they came, each to its end in a task of its
/// own: the next starts only once the one before has finished, and a caller's cancellation never stops one halfway.
/// An operation must not run another on the same lane, which would wait for itself.
final class AsyncLane: Sendable {

    private let tail = Mutex<Task<Void, Never>?>(nil)

    func run<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        let task = tail.withLock { tail -> Task<Value, Never> in
            let previous = tail
            let task = Task {
                await previous?.value
                return await operation()
            }
            tail = Task { _ = await task.value }
            return task
        }
        return await task.value
    }
}
