/// Recovery is the single next-step instruction an action supplies.
public enum Recovery: Sendable, Hashable {
    public enum Blocked: String, Sendable, CaseIterable {
        case notFound = "not_found", ambiguous, unreachable, disabled, destructive
    }

    case `continue`, observe, doNotRepeat, changeTarget(Blocked), askPerson, retry

    public var text: String {
        switch self {
        case .continue: "continue"
        case .observe: "observe"
        case .doNotRepeat: "do_not_repeat"
        case .changeTarget(let reason): "change_target(\(reason.rawValue))"
        case .askPerson: "ask_person"
        case .retry: "retry"
        }
    }
}

/// NotSentCause classifies a refusal before any input was delivered.
public enum NotSentCause: String, Sendable, CaseIterable {
    case targetUnreachable, seatNotReady, humanIntervention, inputAuthorityExpired
    case needsConsent, destructiveUnverifiable, disabled, other
}
