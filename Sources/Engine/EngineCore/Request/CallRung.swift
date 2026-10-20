//
//  CallRung.swift
//  Braus
//

/// CallRung is the rung the last gesture of a call took (M05). On the MacDriver: the accessibility action it performed
/// (`accessibility`, rung 1) or the events it posted to the process in place (`inPlace`, rung 2), what it did in the
/// driver's own words, and why rung 1 was passed over when it was; the actuator's note of that gesture. On the Seat:
/// the call its receipt says posted the last send's events (`seatPublicProcess`, `CGEventPostToPid`;
/// `seatSkyLightProcess`, `SLEventPostToPid`; `seatAccessibilityAction`, an accessibility action with no event), with
/// the send's counts as `how` and nothing skipped. On the web: the DevTools Input commands the last gesture was sent
/// as (`webInputEvent`), with the method's name, the commands planned, handed to the connection and acknowledged by
/// the browser, and how the sequence ended, as `how`; an acknowledgement is not an effect. Taken once by the call
/// that sent the gesture, never inferred from the tool called, the consent or the answer's words. It names the last
/// gesture the call sent, not the whole sequence a typed text makes; a call that sent no gesture, or a foreground
/// (HID) call, has none.
public struct CallRung: Sendable, Equatable {

    public enum Rung: String, Sendable, Equatable, Hashable, CaseIterable {
        case accessibility
        case inPlace = "in_place"
        case seatPublicProcess = "seat_public_process"
        case seatSkyLightProcess = "seat_skylight_process"
        case seatAccessibilityAction = "seat_accessibility_action"
        case webInputEvent = "web_input_event"
    }

    public let rung   : Rung
    /// What the rung did, the driver's sentence ("selected AXRow", "events to the process").
    public let how    : String
    /// Why rung 1 was passed over, one reason per line, empty when it ran.
    public let skipped: [String]

    public init(rung: Rung, how: String, skipped: [String] = []) {
        self.rung    = rung
        self.how     = how
        self.skipped = skipped.filter { !$0.isEmpty }
    }
}
