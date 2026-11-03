import Foundation
import Switches

/// SecondLook permits one additional reading of an unknown effect, never another delivery.
public enum SecondLook: Equatable, Sendable {
    case wait
    case readOnly

    private enum Arm: String, Sendable { case off, on }

    /// Whether second readings are enabled for this call. The historical behavior is the default.
    public static var isEnabled: Bool {
        SwitchBoard.current.arm("second_look", default: Arm.off) == .on
    }

    /// Selects a reading only for a sent gesture whose effect is still unknown.
    public static func mode(for check: OperationCheck?, alreadyLooked: Bool) -> SecondLook? {
        guard !alreadyLooked, let check, check.verdict == .unknown else { return nil }
        switch check.performed {
        case .none: return nil
        case .uncertain: return .readOnly
        case .requested, .substitute:
            return check.limits.contains(.settleCapped) || check.limits.contains(.settleUnwatched) ? .wait : nil
        }
    }

    /// Returns the budget remaining since the last gesture ended, clamped to zero.
    public static func remaining(budget: Duration, since gestureEnded: ContinuousClock.Instant,
                                 now: ContinuousClock.Instant) -> Duration {
        max(.zero, budget - max(.zero, gestureEnded.duration(to: now)))
    }

    /// Withdraws the interrupted reading while keeping the first verdict and delivery evidence.
    public static func cut(_ first: ActOutcome) -> ActOutcome {
        first.with(scene: nil).with(check: first.withStatedCheck.check?.adding([.noAfterScene]))
            .with(lookedAgain: false, waited: first.waited)
    }
}
