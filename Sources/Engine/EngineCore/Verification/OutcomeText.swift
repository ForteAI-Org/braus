/// OutcomeKey selects catalogue prose using structural codes, never application values.
public struct OutcomeKey: Sendable, Hashable {
    public let outcome: Outcome
    public let verb: String
    public let cause: String?

    public init(outcome: Outcome, verb: String, cause: String? = nil) {
        self.outcome = outcome
        self.verb = verb
        self.cause = Self.stableCause(cause)
    }

    static func stableCause(_ cause: String?) -> String? {
        guard let code = cause?.split(separator: "#", maxSplits: 1).first,
              !code.isEmpty, code.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 || $0 == 46 }) else {
            return nil
        }
        return String(code)
    }
}

/// OutcomeText supplies bounded messages without echoing application data or error text.
public enum OutcomeText {
    public static func message(_ key: OutcomeKey, label: String?) -> String {
        if key.cause == "thrown" {
            return key.outcome.gesture == .uncertain
                ? "The call ended before its effect could be read."
                : "The call ended before sending input."
        }
        if key.cause == "remote_content_refused.opens_list" { return "The control opens a list of choices." }
        if key.cause == "remote_content_refused.wrong_element" { return "The input point belongs to another control." }
        switch key.outcome.effect {
        case .confirmed: return "The requested state is present."
        case .absent: return "The reading did not confirm the requested effect."
        case .unknown(.stillChanging): return "The application was still changing at the end of the wait."
        case .unknown(.notWatched): return "The wait could not watch the application's response."
        case .unknown(.notClassified): return "The effect could not be attributed to the requested gesture."
        case .unknown(.notReadable): return "The effect could not be read."
        case .notApplicable:
            switch key.outcome.recovery {
            case .continue: return "No input was needed."
            case .askPerson: return "This step requires the person's consent."
            case .changeTarget(.notFound): return "The requested target was not found."
            case .changeTarget(.ambiguous): return "Several controls match the requested target."
            case .changeTarget(.disabled): return "The requested control is disabled."
            case .changeTarget(.destructive): return "This step's irreversible effect cannot be checked."
            case .changeTarget(.unreachable): return "The requested control could not receive input."
            case .retry: return "The input seat was not ready."
            case .observe: return "The previous observation no longer authorizes input."
            case .doNotRepeat: return "No input was sent."
            }
        }
    }
}
