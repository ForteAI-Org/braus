//
//  AbandonableRead.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 16/10/2026.
//

import Dispatch
import Synchronization

/// AbandonableRead runs a blocking read on a thread of its own for an async caller that may be
/// cancelled. A caller cancelled while the read runs is answered at once with `CancellationError`:
/// the read is asked to stop (`stop`), and one that cannot stop finishes unobserved, its result
/// dropped. A read never starts for a caller already cancelled.
///
/// Vision answers a request's `cancel()` only between its stages: loading its model and running it
/// on the Neural Engine have each kept a stop of `braus chat` waiting about fifteen seconds. The
/// caller does not wait for them; the read's thread and the work it holds end when the read does.
public enum AbandonableRead {

    public static func run<Value: Sendable>(
        _ read: @escaping @Sendable () throws -> Value,
        stop: @escaping @Sendable () -> Void = {}
    ) async throws -> Value {
        try Task.checkCancellation()
        let pending = Pending<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.wait(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    pending.finish(Result { try read() })
                }
            }
        } onCancel: {
            stop()
            pending.finish(.failure(CancellationError()))
        }
    }

    /// The caller's continuation, resumed once: by the read's end or by the cancellation, whichever
    /// comes first. A cancellation that comes before the caller waits leaves nothing to start.
    private final class Pending<Value: Sendable>: Sendable {

        private enum State {
            case starting
            case waiting(CheckedContinuation<Value, any Error>)
            case finished
        }

        private let state = Mutex(State.starting)

        /// Whether the read should start: false when the caller was already answered.
        func wait(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
            let answered = state.withLock { state -> Bool in
                guard case .starting = state else { return true }
                state = .waiting(continuation)
                return false
            }
            if answered { continuation.resume(throwing: CancellationError()) }
            return !answered
        }

        func finish(_ result: Result<Value, any Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
                switch state {
                    case .starting:
                        state = .finished
                        return nil
                    case .waiting(let continuation):
                        state = .finished
                        return continuation
                    case .finished:
                        return nil
                }
            }
            continuation?.resume(with: result)
        }
    }
}
