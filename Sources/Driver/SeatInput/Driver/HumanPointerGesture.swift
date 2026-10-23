import Foundation
import SeatCore
import Synchronization

/// A bounded, single-consumer stream for one left-button gesture. The producer
/// supplies observed coordinates at human speed; it never waits for a model.
/// Preparation and process exclusion belong to the consuming Driver scope.
nonisolated public final class HumanPointerGesture: Sendable {
    public enum Refusal: Error, Sendable, Equatable {
        case closed, overflow, incomplete, expired, unsupported
    }

    package enum Phase: Sendable, Equatable { case down, dragged, up }

    private struct Sample: Sendable {
        let location: InputLocation
        let modifiers: Modifiers
        let released: Bool
    }

    private struct State {
        var claimed = false
        var accepting = true
        var failure: Refusal?
    }

    public let initialLocation: InputLocation
    public let initialModifiers: Modifiers
    public let clickCount: Int
    private let stream: AsyncThrowingStream<Sample, any Error>
    private let continuation: AsyncThrowingStream<Sample, any Error>.Continuation
    private let state = Mutex(State())

    public init(at location: InputLocation, modifiers: Modifiers = [], clickCount: Int = 1, capacity: Int = 256) {
        precondition((1...1024).contains(capacity))
        initialLocation = location
        initialModifiers = modifiers
        self.clickCount = clickCount
        (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    public func move(to location: InputLocation, modifiers: Modifiers = []) throws {
        try enqueue(Sample(location: location, modifiers: modifiers, released: false))
    }

    public func release(at location: InputLocation, modifiers: Modifiers = []) throws {
        try enqueue(Sample(location: location, modifiers: modifiers, released: true))
    }

    public func cancel() { fail(.incomplete) }

    private func fail(_ refusal: Refusal) {
        state.withLock {
            $0.failure = $0.failure ?? refusal
            $0.accepting = false
            continuation.finish(throwing: refusal)
        }
    }

    private func enqueue(_ sample: Sample) throws {
        try state.withLock {
            guard $0.accepting else { throw $0.failure ?? .closed }
            switch continuation.yield(sample) {
            case .enqueued:
                if sample.released {
                    $0.accepting = false
                    continuation.finish()
                }
            case .dropped:
                $0.failure = .overflow
                $0.accepting = false
                continuation.finish(throwing: Refusal.overflow)
                throw Refusal.overflow
            case .terminated:
                $0.accepting = false
                throw Refusal.closed
            @unknown default:
                $0.accepting = false
                $0.failure = .closed
                continuation.finish(throwing: Refusal.closed)
                throw Refusal.closed
            }
        }
    }

    /// A drag recipe for endpoint selection and preparation, not an accumulated
    /// path to replay. The fragments below build exactly one event each.
    package var command: InputCommand {
        .drag(points: [initialLocation, initialLocation, initialLocation], modifiers: initialModifiers)
    }

    /// The posting closure must throw before posting, or return after exactly
    /// one post. Cleanup is only an up for this scope's successful down.
    package func consume(
        isolation: isolated (any Actor)? = #isolation,
        within: Duration = .seconds(30),
        post: (Phase, InputLocation, Modifiers, Bool) async throws -> Void
    ) async throws {
        guard (1...InputCommand.maximumClickCount).contains(clickCount) else {
            throw InputFailure.invalidClickCount(requested: clickCount, maximum: InputCommand.maximumClickCount)
        }
        guard within > .zero, within <= .seconds(30) else { throw Refusal.expired }
        try state.withLock {
            guard !$0.claimed else { throw Refusal.closed }
            $0.claimed = true
        }
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: within) } catch { return }
            self?.fail(.expired)
        }
        defer {
            expiry.cancel()
            state.withLock { $0.accepting = false }
            continuation.finish()
        }
        var held = false
        var count = 0
        var last = initialLocation
        var modifiers = initialModifiers
        do {
            try Task.checkCancellation()
            if let failure = state.withLock({ $0.failure }) { throw failure }
            try await post(.down, last, modifiers, false)
            held = true
            count += 1
            for try await sample in stream {
                try Task.checkCancellation()
                if let failure = state.withLock({ $0.failure }) { throw failure }
                try await post(sample.released ? .up : .dragged, sample.location, sample.modifiers, false)
                count += 1
                last = sample.location
                modifiers = sample.modifiers
                if sample.released { held = false; return }
            }
            throw Refusal.incomplete
        } catch {
            var releaseFailure: (any Error)?
            if held {
                do { try await post(.up, last, modifiers, true); count += 1 }
                catch { releaseFailure = error }
            }
            throw HumanPointerFailure(postedEventCount: count, cause: error, releaseFailure: releaseFailure)
        }
    }
}

/// Partial delivery is never reported as an action that can be replayed.
nonisolated public struct HumanPointerFailure: Error, Sendable {
    public let postedEventCount: Int
    public let cause: any Error
    public let releaseFailure: (any Error)?
}

/// Optional capability: senders without progressive delivery refuse explicitly.
nonisolated public protocol HumanPointerSending: Sendable {
    func sendHumanPointer(
        _ gesture: HumanPointerGesture,
        to window: WindowReference,
        correlationID: Int64,
        platform: any InputPlatform,
        token: InputCommandGate.HumanInput,
        beforeFirstPost: @escaping @Sendable () async throws -> Void,
        beforeContinuation: @escaping @Sendable () async throws -> Void
    ) async throws -> InputReceipt
}
