import PerceptionCore

/// OutcomeKey selects catalogue prose using structural codes, never application values.
public struct OutcomeKey: Sendable, Hashable {
    public let outcome: Outcome
    public let verb: String
    public let cause: String?
    public let noop: NoopKind?

    public init(outcome: Outcome, verb: String, cause: String? = nil, noop: NoopKind? = nil) {
        self.outcome = outcome
        self.verb = verb
        self.cause = Self.stableCause(cause)
        self.noop = noop
    }

    static func stableCause(_ cause: String?) -> String? {
        guard let code = cause?.split(separator: "#", maxSplits: 1).first,
              !code.isEmpty, code.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 || $0 == 46 }) else {
            return nil
        }
        return String(code)
    }
}

/// OutcomeText supplies bounded messages and quotes application data as text.
public enum OutcomeText {
    /// Fixed observations shared by screen predicates and their model catalogue.
    public static let expectationApplicationAbsent = "the application is not running"
    public static let expectationWindowOpen = "a window with that title is open"
    public static let expectationWindowAbsent = "no window with that title"
    public static let expectationWindowStillOpen = "a window with that title is still open"
    public static let expectationSceneUnavailable = "no session of the application to read the scene"
    public static let expectationOutsideWindow = " past the window's edge"
    public static let expectationElementPresent = "the element is in the scene"
    public static let expectationElementAbsent = "no element with that label in the scene"
    public static let expectationElementStillPresent = "the element is still in the scene"
    public static let expectationValueUnreadable = "the element shows no value Braus can read"
    public static let expectationValueExpected = "the element shows the value expected"
    public static let expectationOutsideValueExpected = "the element past the window's edge shows the value expected"
    public static let expectationElement = "the element"
    public static let expectationValueDifferent = " shows another value"
    public static let expectationStateUnreadable = " shows no state Braus can read"
    public static let expectationStateExpected = "the element is in the state expected"
    public static let expectationStateDifferent = "the element is in another state"
    public static let expectationCensusUnreadable = "the window census could not be read"
    public static let expectationScenesIncomparable = "the scenes could not be compared"
    public static let expectationAlreadySatisfied = "already in the expected state"

    public static let choiceReadBackUnavailable = "The choice could not be read back."
    public static let selectedChoicePresent = "The selected choice is present."
    public static let choiceStillUnconfirmed = "The choice is still unconfirmed; do not choose it again blindly."

    public static let commandObservationFailure = " Observation after dispatch failed: "
    public static let commandObservationRecovery = ". Do not repeat this command. "
        + "Observe the session before further input. If observation stays unavailable, stop and report this error."
    public static let commandWindowsChanging = ": windows kept changing during observation. Do not repeat this command. "
    public static let commandWindowsChangingRecovery = "Observe the session before further input."

    public static func changingWindows(afterPress pressed: String) -> String {
        "pressed \(pressed)" + commandWindowsChanging + commandWindowsChangingRecovery
    }

    /// Fixed refusal text shared with the model catalogue without depending on the delivery layer.
    public static let humanInterventionRefusal = "The person is controlling the application."

    public static let protectedPathRefusal =
        "Changing a protected path needs the person's confirmation; nothing was done."

    public static let committingInputConsentRefusal =
        "This committing input sends a message: refused. If you want the agent to do this, "
        + "the person must allow destructive actions."

    public static let committingInputReadBackRefusal =
        "This committing input sends a message, whose effect this route cannot read back: refused, whatever "
        + "the person allows. Use an adapter that reads its effect back."

    /// Quotes third party text on one line, escaping apostrophes and bounding the entire quote to 48 characters.
    public static func quoted(_ text: String) -> String {
        let tokens = SceneSnapshot.inline(text).map { character in
            character == "'" || character == "\\" ? "\\" + String(character) : String(character)
        }
        let length = tokens.reduce(0) { $0 + $1.count }
        let limit = length > 46 ? 45 : 46
        var content = ""
        for token in tokens {
            guard content.count + token.count <= limit else { break }
            content += token
        }
        return "'" + content + (length > 46 ? "…" : "") + "'"
    }

    /// Describes a destructive label refused before the person grants consent.
    public static func destructiveRefusal(_ label: String) -> String {
        "\(quoted(label)) looks destructive/irreversible: refused. If you want the agent to do this, "
            + "the person must allow destructive actions."
    }

    /// Renders application values within an effect using the same bounded quoting as action labels.
    public static func summary(_ effect: SceneEffect) -> String {
        switch effect {
        case .windowTitleChanged(let title):
            return "navigates to \(quoted(title))"
        case .menuOpened(let labels):
            return "opens menu(\(labels.prefix(3).map(quoted).joined(separator: "|"))\(labels.count > 3 ? "…" : ""))"
        case .valueChanged(let label, let value):
            return "\(quoted(label)) now reads \(quoted(value))"
        case .stateFlip, .elementsAppeared, .elementsDisappeared, .textSelectionChanged:
            return effect.summary
        }
    }

    /// Lists ambiguous candidates with bounded labels and selectors, retaining the scene's positions.
    public static func disambiguation(in scene: SceneSnapshot, target: String) -> String {
        scene.candidates(target: target).prefix(6).map { element in
            let selector = (element.container ?? element.section).map { "section:\(quoted($0))" }
                ?? "id:\(element.id)"
            let role = element.role.map { " role:\(quoted($0))" } ?? ""
            return "\(selector) label:\(quoted(element.label))\(role) \(SceneSnapshot.place(element.bounds))"
        }.joined(separator: " OR ")
    }

    public static func message(_ key: OutcomeKey, label: String?) -> String {
        if key.noop == .substituted {
            return "A menu was open and was closed instead; the click was not made."
        }
        switch key.cause {
        case "no_session": return "No session is open. Open a session before sending input."
        case "memory_unconfirmed": return "Memory did not confirm this step's start; nothing was sent."
        case "uncertainty_refusal": return "An earlier effect is uncertain; this dependent step was not sent."
        case "historical_value_refusal": return "This step uses a historical value that the current task has not authorized; nothing was sent."
        case "invalid_arguments": return "The call's arguments were refused; correct them before retrying."
        default: break
        }
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
