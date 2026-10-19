//
//  SeatActuator.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
#if BRAUS_PHASES
import PhaseSignposts
#endif
import SeatCapture
import SeatCore
import SeatInput
import SeatSession

/// SeatActuator is `Actuating` over the Seat: every gesture becomes one Command admitted under one
/// Observation Reference inside a Turn, and the receipts are kept until the engine says what it saw.
/// `confirm` answers each receipt with that verdict and gives the Turn back, which is the Seat's own
/// rule: an event that went out is never repeated, and a Turn is released only once every Command is
/// confirmed. One action's gestures share one Turn.
///
/// A Command is addressed by the observation it was decided on, never by a window, and a complete
/// Command consumes it. So the first gesture of an action rides the observation the scene was
/// perceived from, and each gesture after it takes a new one: the engine's actions are successions
/// of gestures, and the succession is the consumer's to orchestrate. The first recipient and
/// frame bind that succession until confirmation; a changed target stops the remaining gestures.
///
/// A click is routed only through that observation's own window geometry, so a point outside the
/// observed window, or outside the region a hosted sheet's picture covers, is refused rather than
/// posted somewhere: pop-ups are chosen with the keyboard, and the engine already does so. The
/// application is never activated; the seat never raises anything.
public actor SeatActuator: Actuating {

    private let target: SeatTarget
    private var turn: Turn?
    private var receipts: [InputReceipt] = []
    private var lastRoute: DeliveryRoute = .posted
    private var inputSurface: (identity: WindowIdentity, frame: CGRect)?

    public init(target: SeatTarget) {
        self.target = target
    }

    public func perform(_ gesture: Gesture, in processID: pid_t) async throws {
        try await send(gesture, expecting: nil, in: processID)
    }

    public func perform(_ gesture: Gesture, expecting label: String, in processID: pid_t) async throws {
        try await send(gesture, expecting: label, in: processID)
    }

    /// `deliver`, its errors as the engine reads them: a refusal before any event as `GestureNotSent`, a stop after
    /// one as `GestureInterrupted`, any other as it is.
    private func send(_ gesture: Gesture, expecting label: String?, in processID: pid_t) async throws {
        do {
            try await deliver(gesture, expecting: label, in: processID)
        } catch {
            throw Self.unsent(error) ?? Self.interrupted(error) ?? error
        }
    }

    /// The refusal as `GestureNotSent` when the seat refused before posting any event of the gesture, and nil
    /// for every other error, which stays a delivery whose effect is unknown: the input endpoint discovery's
    /// refusals (`AgentSeat.send` resolves the endpoint before preflight and before any post), the preflight's
    /// own stop (`SeatInterruption.beforeAnyEvent`, such as a sheet that changed size since the scene), the seat
    /// not being ready (`seatNotReady` is always thrown before a post), a remote panel's refusal that cannot have
    /// taken effect, and a point or a gesture this actuator refuses itself.
    static func unsent(_ error: any Error) -> GestureNotSent? {
        switch error {
            case let refusal as InputEndpointRefusal:
                return GestureNotSent(reason: "endpoint_refused", sentence: sentence(for: refusal))
            case let refusal as RemoteContentActuationRefusal where !refusal.mayHaveTakenEffect:
                return GestureNotSent(reason: "remote_content_refused", sentence: refusal.description)
            case SeatDrivingFailure.pointOutsideTarget:
                return GestureNotSent(reason: "point_outside_window", sentence:
                    "That point is outside the window the seat holds. Act on an element of the scene.")
            case SeatDrivingFailure.gestureUnsupported(let gesture):
                return GestureNotSent(reason: "gesture_unsupported", sentence: "The seat has no delivery for \(gesture).")
            case SessionFailure.seatNotReady(let state):
                return GestureNotSent(reason: "seat_not_ready", sentence: sentence(forSeatIn: state))
            case let stop as SeatInterruption where stop.beforeAnyEvent:
                let why = stop.issues.map(Self.words).joined(separator: "; ")
                return GestureNotSent(reason: "seat_preflight", sentence: why.prefix(1).uppercased() + why.dropFirst()
                    + ". Observe again and act on the new scene.")
            default:
                return nil
        }
    }

    /// The seat's stop once a gesture's first event may have gone out, in words: its effect stays unknown, and the
    /// engine still reports the gesture as delivered. Nil for any other error.
    static func interrupted(_ error: any Error) -> GestureInterrupted? {
        guard let stop = error as? SeatInterruption else { return nil }
        return GestureInterrupted(sentence: "the seat stopped it: " + stop.issues.map(Self.words).joined(separator: "; ")
            + "; it may have taken effect, so observe before any retry")
    }

    /// A seat that refused for its state, in words: it throws that before posting anything, so no retry risks a repeat.
    static func sentence(forSeatIn state: SeatState) -> String {
        switch state {
            case .starting:
                "The seat was still taking in a window that had just opened, and nothing was sent. "
                    + "Observe again and act on the new scene."
            case .waiting:
                "The application is in front of the person's screen, so nothing was sent. Observe again later."
            case .recovering:
                "The seat is recovering, and nothing was sent. Observe again."
            default:
                "The seat was \(state.rawValue) and nothing was sent; observe again."
        }
    }

    /// An Issue as the model reads it. `SeatIssue` carries no prose and leaves the sentence to its consumer, as
    /// `SeatErrorMapper` and `SeatAdmission` write theirs.
    static func words(_ issue: SeatIssue) -> String {
        switch issue {
            case .geometryChanged       : "the window moved or changed size since that scene"
            case .windowStashed         : "the window is a Stage Manager thumbnail and stayed one"
            case .windowUnavailable     : "the window could not be read just then"
            case .snapshotChanged       : "two readings of the window disagreed and have to be confirmed again"
            case .identityChanged       : "the window or its process is not the one that was observed"
            case .processUnavailable    : "the application is gone"
            case .targetActivated       : "the application came to the front of the person's screen, and it is left there"
            case .displayChanged        : "the background display or the screens around it changed"
            case .fenceUnavailable      : "the cursor fence is not active"
            case .cursorInterference    : "the pointer moved in a way the person's input does not explain"
            case .ambiguousEffect       : "the effect of the last input is unknown, and repeating it could do it twice"
            case .recoveryExhausted     : "the seat's recovery ran out of attempts"
            case .monitorUnavailable    : "the preview of the background display is unavailable"
            case .preparationNotRestored: "the application's internal state did not go back after the input"
            case .keysNotReleased       : "held keys could not be released safely"
            case .contextMenuLeftOpen   : "a contextual menu the seat opened stayed on the screen"
        }
    }

    /// What an input endpoint refusal means to the model, in words: the enum's own text names types.
    static func sentence(for refusal: InputEndpointRefusal) -> String {
        switch refusal {
            case .noNodeAtPoint:
                "Accessibility answers no element at that point of the window. Observe again and name a control."
            case .pointOutsideSurface:
                "That point is outside the window the seat is operating. Act on an element of its scene."
            case .subtreeUnreadable:
                "The window's accessibility gave the seat no control to send it to: its content may be drawn by "
                    + "another process, as a file panel's is. Observe again; click the field or the button you "
                    + "mean first, or take another route."
            case .identityUnattested:
                "The window that would receive it has no complete identity in the window server. Observe again."
            case .identityChangedDuringDiscovery:
                "The window that would receive it changed while it was being read. Observe again."
            case .geometryUnavailable:
                "The window's geometry could not be read. Observe again."
            case .notContainedInSurface:
                "The window that would receive it is not drawn inside the one the seat is operating."
            case .recipientModallyBlocked:
                "That window is blocked by a dialog in front of it: answer the dialog first."
            case .incoherentEndpoint:
                "The window's facts do not name one recipient for it. Observe again."
        }
    }

    private func deliver(_ gesture: Gesture, expecting label: String?, in processID: pid_t) async throws {
        #if BRAUS_PHASES
        let preparing = PhaseInterval.begin("delivery.prepare")
        #endif
        let seat = try await target.agentSeat()
        let turn = try await heldTurn(on: seat)
        let observation = try await target.currentObservation()
        let surface = observation.reference.recipient
        let frame = observation.geometry.window.frame
        if let inputSurface,
           inputSurface.identity != surface || inputSurface.frame != frame {
            throw GestureNotSent(
                reason: "input_target_changed",
                sentence: "The window changed during this input. The remaining gesture was not sent; "
                    + "observe the current dialog before deciding what to do next."
            )
        }
        inputSurface = (surface, frame)
        #if BRAUS_PHASES
        preparing.end()
        let delivery = PhaseInterval.begin("delivery")
        defer {
            delivery.end()
            FrameProbe.markInput()
        }
        #endif
        switch gesture {
            case .click(let point, let button, let count):
                guard (1...InputCommand.maximumClickCount).contains(count) else {
                    throw SeatDrivingFailure.gestureUnsupported("a \(count)-click")
                }
                let location = try routed(point, in: observation)
                let mouse: SeatCore.MouseButton = button == .left ? .left : .right
                receipts.append(try await seat.send(
                    .click(location, button: mouse, count: count),
                    observation: observation.reference,
                    turn       : turn,
                    expecting  : label
                ))
            case .scroll(let point, let deltaY, _):
                let location = try routed(point, in: observation)
                receipts.append(try await seat.send(
                    .scroll(location, deltaY: Int32(deltaY)),
                    observation: observation.reference,
                    turn       : turn
                ))
            case .key(let code, let modifiers):
                let shortcut = Shortcut(.virtualKey(CGKeyCode(code)), holding: Self.modifiers(modifiers))
                receipts.append(try await seat.send(shortcut, observation: observation.reference, turn: turn))
            case .character(let character, let modifiers):
                // The seat resolves a character through the installed layout, as a menu matches it.
                let shortcut = Shortcut.character(character, holding: Self.modifiers(modifiers))
                receipts.append(try await seat.send(shortcut, observation: observation.reference, turn: turn))
            case .type(let text):
                receipts.append(try await seat.send(.text(text), observation: observation.reference, turn: turn))
            case .insert(let text):
                receipts.append(try await seat.send(.insertText(text), observation: observation.reference, turn: turn))
            case .drag(let start, let end):
                // Both ends are routed under the one observation, so a drag leaving the window is refused.
                let path = InputCommand.drag(
                    from: try routed(start, in: observation),
                    to  : try routed(end, in: observation)
                )
                receipts.append(try await seat.send(path, observation: observation.reference, turn: turn))
        }
        lastRoute = receipts.last?.route.poster == .accessibilityAction ? .accessibility : .posted
        // The events are out: the observation they rode has spent its authority and the next
        // gesture needs a new one.
        await target.spendObservation()
    }

    public func lastDeliveryRoute(in processID: pid_t) async -> DeliveryRoute { lastRoute }

    /// A seat that refuses a confirmation or a release has already failed its Turn and reports that
    /// on its own event stream; there is nothing more to do from here, so those errors are dropped.
    public func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {
        #if BRAUS_PHASES
        let confirming = PhaseInterval.begin("delivery.confirm")
        defer { confirming.end() }
        #endif
        guard let turn else { return }
        let confirmation: EffectConfirmation = switch effect {
            case .observed: .observed
            case .absent  : .absent
            case .unknown : .unknown
        }
        if let seat = try? await target.agentSeat() {
            for receipt in receipts { try? await seat.confirm(receipt, confirmation) }
            try? await seat.release(turn)
        }
        receipts = []
        inputSurface = nil
        lastRoute = .posted
        self.turn = nil
    }

    private func heldTurn(on seat: AgentSeat) async throws -> Turn {
        if let turn { return turn }
        let acquired = try await seat.acquire()
        turn = acquired
        return acquired
    }

    /// The point under the observation the Command will be admitted with, or a refusal when it
    /// falls outside the window that observation is of, or outside the region its picture covers.
    private func routed(_ point: CGPoint, in observation: SeatObservationDelivery) throws -> InputLocation {
        let region: CGRect? = if case .attestedWindowRegion? = observation.captureTarget {
            observation.frame.geometry.screenRect
        } else {
            nil
        }
        guard let location = Self.location(of: point, in: observation.geometry, region: region) else {
            throw SeatDrivingFailure.pointOutsideTarget(point)
        }
        return location
    }

    /// A point inside the observed window, or inside the region a hosted sheet's picture covers. A
    /// sheet can extend past its host (TextEdit's Save sheet, 05/10/2026, once expanded), and the
    /// picture covers both: such a point keeps the host's geometry, and the seat admits it against
    /// the sheet's own attested frame or refuses it.
    static func location(
        of point   : CGPoint,
        in geometry: WindowGeometryObservation,
        region     : CGRect?
    ) -> InputLocation? {
        if let location = InputLocation(screenPoint: point, observedIn: geometry) { return location }
        guard let region, point.x.isFinite, point.y.isFinite,
              point.x >= region.minX, point.y >= region.minY, point.x < region.maxX, point.y < region.maxY
        else { return nil }
        let origin = geometry.window.frame.origin
        return InputLocation(
            screenPoint       : point,
            windowPointFromTop: CGPoint(x: point.x - origin.x, y: point.y - origin.y),
            observedIn        : geometry
        )
    }

    private static func modifiers(_ modifiers: KeyModifiers) -> Modifiers {
        var held: Modifiers = []
        if modifiers.contains(.command) { held.insert(.command) }
        if modifiers.contains(.shift)   { held.insert(.shift) }
        if modifiers.contains(.option)  { held.insert(.option) }
        if modifiers.contains(.control) { held.insert(.control) }
        return held
    }
}

/// A seat's stop that may have followed an event of the gesture: a delivery whose effect is unknown, said in
/// words, because the engine prints the error it is given.
public struct GestureInterrupted: Error, Sendable, Equatable, CustomStringConvertible {

    public let sentence: String

    public var description: String { sentence }
}

