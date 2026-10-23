import Foundation
import Synchronization

/// A synchronous stop at command boundaries. A command already posting stays
/// atomic (a down is never abandoned without its up); the next command cannot
/// start while focus is unconfirmed. No input is queued or replayed here.
///
/// ## Why the stop is a set of causes and not a flag
///
/// Two stops overlap in practice: the person activates the target while the
/// seat is moving a window onto the stage, and whichever finishes first would
/// reopen the gate for the other one if the stop were a single boolean. So the
/// gate is closed while **any** cause is present and each owner removes only
/// its own. The type is `public` because `CommandSending` names it; every
/// member that can act on it stays `package`, so a consumer can hold one and
/// do nothing with it.
nonisolated public final class InputCommandGate: Sendable {

    /// Why input is stopped. Each case has one owner and only that owner
    /// resolves it.
    package enum PauseCause: Sendable, Hashable, CaseIterable {

        /// The person's focus is being restored. `UserFocusRecovery` opens it
        /// on activation and closes it when the focused user window is
        /// verified twice or the person took control.
        case focusRecovery

        /// The seat is staging a window or moving its operating target.
        /// `AgentSeat` opens and closes it around one transaction.
        case windowTransfer

        /// Focus recovery stopped. Deliberately terminal: nothing resolves it,
        /// so a seat whose recovery went away never posts again.
        case focusRecoveryStopped

        /// The person stopped the seat themselves. Terminal like the one above,
        /// and closed before any teardown begins: a panic that tore down first
        /// left the gate open for whatever the run in flight tried next. The
        /// Command already admitted stays atomic, so a release is never
        /// abandoned halfway by this.
        case deliberateStop

        /// How this cause is reported to a consumer.
        package var reason: InputPauseReason {
            switch self {
                case .focusRecovery       : .focusRecovery
                case .windowTransfer      : .windowTransfer
                case .focusRecoveryStopped: .focusRecoveryStopped
                case .deliberateStop      : .deliberateStop
            }
        }
    }

    /// HumanInput identifies one intervention on one gate. It conveys no window,
    /// coordinate or containment authority and cannot be constructed by a consumer.
    public struct HumanInput: Sendable, Equatable {
        fileprivate let gate: UUID
        fileprivate let episode: UUID
    }

    private struct State {
        var causes: Set<PauseCause> = []
        var generation = UUID()
        var human: HumanInput?
    }

    private struct Admission: Sendable {
        let gate: UUID
        let generation: UUID
        let human: HumanInput?
    }

    @TaskLocal
    private static var admission: Admission?

    private let id = UUID()
    private let state = Mutex(State())
    private let preparation = Mutex<(@MainActor @Sendable (Int64) async throws -> Void)?>(nil)

    package init() {}

    package var isPaused: Bool { state.withLock { !$0.causes.isEmpty || $0.human != nil } }

    /// The causes holding the gate closed right now, for a report or a test.
    package var pauseCauses: Set<PauseCause> { state.withLock { $0.causes } }

    /// Reports the agent's admission state without borrowing human authority.
    package var pauseReasons: [InputPauseReason] {
        state.withLock {
            ($0.causes.map(\.reason) + ($0.human == nil ? [] : [.humanIntervention])).sorted()
        }
    }

    package func pause(_ cause: PauseCause) { state.withLock { _ = $0.causes.insert(cause) } }

    package func resume(_ cause: PauseCause) { state.withLock { _ = $0.causes.remove(cause) } }

    package func setPreparation(_ prepare: @escaping @MainActor @Sendable (Int64) async throws -> Void) {
        preparation.withLock { $0 = prepare }
    }

    /// Closes agent admission synchronously before the caller suspends its worker.
    /// Common faults remain closed for both sources. Repeated input uses the same episode.
    package func beginHumanInput() throws -> HumanInput {
        try state.withLock {
            let terminal = $0.causes.intersection([.deliberateStop, .focusRecoveryStopped])
            guard terminal.isEmpty else {
                throw InputFailure.inputPaused(terminal.map(\.reason).sorted())
            }
            if let human = $0.human { return human }
            let human = HumanInput(gate: id, episode: UUID())
            $0.generation = UUID()
            $0.human = human
            return human
        }
    }

    package func endHumanInput(_ token: HumanInput) throws {
        try state.withLock {
            guard $0.human == token else {
                throw InputFailure.inputPaused([.inputAuthorityExpired])
            }
            $0.human = nil
            $0.generation = UUID()
        }
    }

    /// Captures authority before a request waits for the driver or preparation.
    /// Nested boundaries retain that authority, so an old request cannot acquire a
    /// fresh generation after a complete intervention passed while it was waiting.
    package func withAdmission<Result: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async throws -> Result {
        let admission = Self.admission ?? state.withLock {
            Admission(gate: id, generation: $0.generation, human: nil)
        }
        return try await Self.$admission.withValue(admission) {
            try check()
            return try await operation()
        }
    }

    package func withHumanInput<Result: Sendable>(
        _ token: HumanInput,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async throws -> Result {
        let admission = try state.withLock {
            guard token.gate == id, $0.human == token else {
                throw InputFailure.inputPaused([.inputAuthorityExpired])
            }
            return Admission(gate: id, generation: $0.generation, human: token)
        }
        return try await Self.$admission.withValue(admission) {
            try check()
            return try await operation()
        }
    }

    package func prepare(correlationID: Int64) async throws {
        try await withAdmission {
            if let prepare = preparation.withLock({ $0 }) {
                try await prepare(correlationID)
            }
            try Task.checkCancellation()
            try check()
        }
    }

    package func check() throws {
        let admission = Self.admission
        let reasons = state.withLock { current -> [InputPauseReason] in
            var reasons = current.causes.map(\.reason)
            if let admission, admission.gate != id || admission.generation != current.generation {
                reasons.append(.inputAuthorityExpired)
            } else if current.human != nil && admission?.human != current.human {
                reasons.append(.humanIntervention)
            }
            return reasons.sorted()
        }
        guard reasons.isEmpty else { throw InputFailure.inputPaused(reasons) }
    }
}
