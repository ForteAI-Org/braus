import Foundation
import Synchronization

/// InterruptibleWait owns the stoppable readings after a gesture, never the call or delivery task.
/// Its mutex serializes stop requests with reader admission. Child tasks inherit the call's task locals.
public final class InterruptibleWait: Sendable {
    @TaskLocal
    public static var current: InterruptibleWait?

    private struct State {
        var isOpen = false
        var stopped = false
        var readers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var isOpen: Bool { state.withLock { $0.isOpen } }
    public var stopRequested: Bool { state.withLock { $0.stopped } }

    /// Requests stop without cancelling the owning call. An active reading returns nil immediately.
    public func requestStop() {
        let stops = state.withLock {
            $0.stopped = true
            return Array($0.readers.values)
        }
        for stop in stops { stop() }
    }

    public func open() { state.withLock { $0.isOpen = true } }
    public func close() { state.withLock { $0.isOpen = false } }

    /// Runs closed readings normally, and open readings in independently cancellable children.
    public func reading<T: Sendable>(_ read: @escaping @Sendable () async -> T?) async -> T? {
        guard isOpen else { return await read() }
        let id = UUID()
        let reader = Reader<T>()
        let admitted = state.withLock {
            guard !$0.stopped else { return false }
            $0.readers[id] = { reader.stop() }
            return true
        }
        guard admitted else { return nil }
        defer { state.withLock { $0.readers[id] = nil } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reader.start(continuation, read: read)
            }
        } onCancel: {
            reader.stop()
        }
    }

    /// Reader resolves its continuation exactly once, even when stop wins before child installation.
    private final class Reader<T: Sendable>: Sendable {
        private struct State {
            var stopped = false
            var continuation: CheckedContinuation<T?, Never>?
            var task: Task<Void, Never>?
        }
        private let state = Mutex(State())

        func start(_ continuation: CheckedContinuation<T?, Never>, read: @escaping @Sendable () async -> T?) {
            let admitted = state.withLock {
                guard !$0.stopped else { return false }
                $0.continuation = continuation
                return true
            }
            guard admitted else { continuation.resume(returning: nil); return }
            let task = Task { self.finish(await read()) }
            let cancel = state.withLock {
                guard !$0.stopped else { return true }
                $0.task = task
                return false
            }
            if cancel { task.cancel() }
        }

        func stop() {
            let (continuation, task) = state.withLock {
                $0.stopped = true
                let result = ($0.continuation, $0.task)
                $0.continuation = nil
                $0.task = nil
                return result
            }
            task?.cancel()
            continuation?.resume(returning: nil)
        }

        private func finish(_ value: T?) {
            let continuation = state.withLock {
                let continuation = $0.continuation
                $0.continuation = nil
                $0.task = nil
                return continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
