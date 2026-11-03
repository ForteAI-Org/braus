import Switches

/// TaskCycleArm selects the existing task contract unless explicitly enabled.
public nonisolated enum TaskCycleArm: String, Sendable {
    case v1, v2
    public static var current: TaskCycleArm { SwitchBoard.current.arm("task_cycle", default: .v1) }
}

/// GuardThreshold bounds unplanned gestures after the guard is armed; zero requires the plan immediately.
public nonisolated struct GuardThreshold: Sendable, Equatable {
    public let gesturesBeforePlan: Int

    public init(gesturesBeforePlan: Int = 0) {
        precondition(gesturesBeforePlan >= 0, "The gesture allowance must be nonnegative")
        self.gesturesBeforePlan = gesturesBeforePlan
    }
}
