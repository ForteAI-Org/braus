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
        if key.cause == "already_refused" {
            return "Already refused here for the same reason; do not repeat this gesture."
        }
        if key.cause == "seat_error" { return "The seat reported an error it does not describe." }
        switch key.cause {
        case "remote_content_refused.gesture_unmeasured": return "A file panel's content is drawn by another process: reach the folder through the sidebar or Go to Folder."
        case "remote_content_refused.pixel_dropdown": return "This file panel dropdown has no accessibility control. The sidebar or Go to Folder can reach its folders."
        case "remote_content_refused.no_element_at_point": return "No accessibility element answers at this point. A named button, row or field can provide another target."
        case "remote_content_refused.outside_remote_content": return "This point is not proved to belong to the window's content."
        case "remote_content_refused.unreadable": return "The window's accessibility could not be read at this point."
        case "remote_content_refused.field_requires_click": return "This field requires entering its editor before accessibility can write text."
        case "remote_content_refused.row_not_text": return "This target is a row: one click selects it and two open it. Text requires a field."
        case "remote_content_refused.control_not_text": return "This target is a clickable control, without a text editor."
        case "remote_content_refused.text_field_clicks": return "This text field accepts one click for a caret or three to select its text."
        case "remote_content_refused.nothing_clickable": return "There is no clickable control at this point."
        case "remote_content_refused.opens_menu": return "The control opens a menu of choices."
        case "remote_content_refused.opens_list": return "The control opens a list of choices."
        case "remote_content_refused.column_view": return "Selection in this column view is unsupported. List view provides selectable rows."
        case "remote_content_refused.wrong_element": return "The input point belongs to another control."
        case "remote_content_refused.web_content": return "This web content cannot receive input through accessibility."
        case "remote_content_refused.action_unsupported": return "The control does not support the requested action; nothing was sent."
        case "remote_content_refused.selection_not_verified": return "The selection may have taken effect, but its selected state could not be read back."
        case "remote_content_refused.selected_not_opened": return "The row was selected; whether it opened is unknown."
        case "remote_content_refused.action_refused": return "The application refused the action, which may still have taken effect."
        default: break
        }
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
