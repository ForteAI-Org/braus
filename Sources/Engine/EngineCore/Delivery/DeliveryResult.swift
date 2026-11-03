/// DeliveryResult records whether gestures went out, independently of their observed effect.
public enum DeliveryResult: Sendable, Equatable {
    case delivered
    case notSent(GestureNotSent)
    case uncertain(UncertainDelivery)
}

/// UncertainDelivery keeps partial delivery facts and the producer's original diagnostic.
/// The detail belongs to the historical answer and the action record, never the new answer.
public struct UncertainDelivery: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case failedAfterEvents = "failed_after_events"
        case stoppedBeforeText = "stopped_before_text"
        case refusedAfterOthers = "refused_after_others"
        case mayHaveTakenEffect = "may_have_taken_effect"
    }

    public let kind: Kind
    public let sentBefore: Int
    public let detail: String
    /// An existing structural cause from the actuator, preserved independently of its diagnostic.
    public let cause: String?

    public init(kind: Kind, sentBefore: Int, detail: String, cause: String? = nil) {
        self.kind = kind
        self.sentBefore = sentBefore
        self.detail = detail
        self.cause = cause
    }
}
