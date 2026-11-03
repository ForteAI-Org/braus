import Foundation
import Synchronization

/// BrainReadControl stops one derived reading, independently of the task that records its facts.
/// Bind it only around read work. Neither an application nor a store retains it.
public final class BrainReadControl: Sendable {
    @TaskLocal public static var current: BrainReadControl?

    private let stopped = Mutex(false)
    private let shouldStop: @Sendable () -> Bool

    public init(shouldStop: @escaping @Sendable () -> Bool = { false }) {
        self.shouldStop = shouldStop
    }

    public func requestStop() { stopped.withLock { $0 = true } }

    public var isStopped: Bool { stopped.withLock { $0 } || shouldStop() }

    public func check() throws {
        if isStopped { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Checks the derived read's explicit stop and its independently cancellable task.
    public static func checkCurrent() throws {
        try Task.checkCancellation()
        try current?.check()
    }
}
