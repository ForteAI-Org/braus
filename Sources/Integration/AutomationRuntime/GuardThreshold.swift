/// GuardThreshold bounds unplanned gestures after the guard is armed; zero requires the plan immediately.
public nonisolated struct GuardThreshold: Sendable, Equatable {
    public let gesturesBeforePlan: Int

    public init(gesturesBeforePlan: Int = 0) {
        precondition(gesturesBeforePlan >= 0, "The gesture allowance must be nonnegative")
        self.gesturesBeforePlan = gesturesBeforePlan
    }
}
