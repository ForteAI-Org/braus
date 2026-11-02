//
//  LendActivity.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import InteractionListener

/// LendActivity infers what the person does with a lent application and decides when Braus asks
/// "Are you done?" or takes the application back by itself. Evidence decides; the delays only
/// bound how long evidence of leaving must last. Pure: it reads the times it is given, never a clock,
/// and `deadline` tells the adapter when to wake once, so idle time costs no wakeups.
///
/// Elsewhere: another application came to the front. Its delay runs only once the person works there
/// (input routed to another application); a look elsewhere with no input is left to the away delay.
/// The lent application hidden or with every window minimized is stronger evidence: a shorter delay
/// that needs no work elsewhere. Coming back to the lent application, input reaching it, the pointer
/// resting on it or one of its menus opening ends the span. Away: no input at all on the Mac. Locked
/// or asleep: nobody can answer, so the application is taken back without asking after `lockedDelay`;
/// unlocking or waking before then changes nothing. Every window closed asks at once; the application
/// quitting ends the episode at once. Nothing is decided while `held`: the lend still landing.
///
/// A No, or input reaching the lent application while the question is open, doubles that trigger's
/// delay until the person works in the application again after the question.
nonisolated public struct LendActivity: Sendable {

    /// What the person is doing, from the latest evidence.
    public enum State: String, Sendable {
        case working, reading, elsewhere, away, locked, closed
    }

    /// Why Braus asks, or takes the application back.
    public enum Trigger: String, Sendable {
        case elsewhere, away, closed, locked, quit
    }

    /// Where a gesture went: the lent application, another one, or nowhere the listener could name.
    public enum Route: Sendable, Equatable {
        case lent, other, unknown
    }

    /// What remains of the lent application's windows: some on screen, all hidden or minimized, none.
    public enum Presence: String, Sendable {
        case shown, tucked, closed
    }

    public enum Answer: Sendable {
        case yes, no, timeout
    }

    public enum Evidence: Sendable, Equatable {

        /// A click, right click, key, typing burst, drag or scroll, and where it went.
        case input(Route)

        /// The pointer came to rest over a window.
        case hover(Route)

        /// An application came to the front.
        case frontmost(Route)

        /// A menu of the lent application opened or closed.
        case menu(open: Bool)

        case windows(Presence)
        case locked(Bool)
        case asleep(Bool)

        /// The lent application quit.
        case quit
    }

    public enum Decision: Sendable, Equatable {
        case ask(Trigger)

        /// Input reached the lent application while the question was open: close it as No.
        case withdraw

        case takeBack(Trigger)
    }

    /// Every delay of the policy, in seconds, and the question's countdown.
    public static let elsewhereDelay: Double = 120
    public static let tuckedDelay   : Double = 30
    public static let awayDelay     : Double = 300
    public static let lockedDelay   : Double = 60
    public static let countdown              = 10

    /// Why the last question was asked or the application taken back, for the worker and the log.
    public private(set) var reason = ""

    private var now           : Double
    private var held          = true
    private var ended         = false
    private var activity      = State.reading
    private var lastInput     : Double
    private var elsewhereSince: Double?
    private var workedElsewhere = false
    private var presence      = Presence.shown
    private var tuckedSince   : Double?
    private var closedSince   : Double?
    private var closedAsked   = false
    private var menuOpen      = false
    private var locked        = false
    private var asleep        = false
    private var lockedSince   : Double?
    private var quitAt        : Double?
    private var asking        : Trigger?
    private var withdrawn     = false
    /// When the last question was answered No: only work after it lifts the back-off.
    private var settledAt     : Double?
    private var elsewhereFactor: Double = 1
    private var awayFactor     : Double = 1

    /// Starts held, at `time`, with the lent application in front or not.
    public init(
        at time    : Double,
        lentInFront: Bool = true
    ) {
        now       = time
        lastInput = time
        if !lentInFront {
            elsewhereSince = time
            activity       = .elsewhere
        }
    }

    public var state: State {
        if quitAt != nil || presence == .closed { return .closed }
        if locked || asleep { return .locked }
        return activity
    }

    /// When the next decision falls due, nil while none can: held, ended, a question open or a menu open.
    public var deadline: Double? { next()?.at }

    /// How long `trigger` waits now, its back-off included.
    public func delay(of trigger: Trigger) -> Double {
        switch trigger {
        case .elsewhere: (tuckedSince != nil ? Self.tuckedDelay : Self.elsewhereDelay) * elsewhereFactor
        case .away     : Self.awayDelay * awayFactor
        case .locked   : Self.lockedDelay
        case .closed, .quit: 0
        }
    }

    /// The lend landed: decisions may fall due from now on.
    public mutating func release(at time: Double) -> Decision? {
        held = false
        return evaluate(at: time)
    }

    /// The deadline came.
    public mutating func tick(at time: Double) -> Decision? {
        evaluate(at: time)
    }

    /// Takes `evidence` that happened at `time`, which may lie a little in the past: the listener reports
    /// a typing burst once it pauses.
    public mutating func receive(
        _ evidence: Evidence,
        at time   : Double
    ) -> Decision? {
        switch evidence {
        case .input(let route):
            lastInput = max(lastInput, time)
            switch route {
            case .lent:
                if endSpan(at: time) { activity = .working }
                if asking != nil {
                    guard !withdrawn else { break }
                    withdrawn = true
                    return .withdraw
                }
                if let settledAt, time > settledAt {
                    elsewhereFactor = 1
                    awayFactor      = 1
                    self.settledAt  = nil
                }
            case .other:
                // Only work since the span began counts: the click that answered No restarts it.
                if let since = elsewhereSince, time >= since { workedElsewhere = true }
                cameBack()
            case .unknown:
                cameBack()
            }
        case .hover(let route):
            lastInput = max(lastInput, time)
            if route == .lent {
                if endSpan(at: time), activity != .working { activity = .reading }
            } else {
                cameBack()
            }
        case .frontmost(let route):
            if route == .lent {
                if endSpan(at: time), activity != .working { activity = .reading }
            } else {
                // A menu of the lent application cannot stay open behind another one.
                menuOpen = false
                leave(at: time)
            }
        case .menu(let open):
            menuOpen  = open
            lastInput = max(lastInput, time)
            if open, endSpan(at: time), activity != .working { activity = .reading }
        case .windows(let presence):
            guard presence != self.presence else { break }
            self.presence = presence
            tuckedSince   = presence == .tucked ? time : nil
            closedSince   = presence == .closed ? time : nil
            closedAsked   = false
            if presence == .tucked { leave(at: time) }
        case .locked(let on):
            locked = on
            lockChanged(at: time)
        case .asleep(let on):
            asleep = on
            lockChanged(at: time)
        case .quit:
            if quitAt == nil { quitAt = time }
        }
        return evaluate(at: time)
    }

    /// The question ended. The answer stands even after a withdrawal: the bubble may have been answered
    /// or timed out first.
    public mutating func answered(
        _ answer: Answer,
        at time : Double
    ) -> Decision? {
        guard let trigger = asking, !ended else { return nil }
        asking    = nil
        withdrawn = false
        switch answer {
        case .yes, .timeout:
            ended  = true
            reason = reason + (answer == .yes
                ? "; the person confirmed being done"
                : "; nobody answered within \(Self.countdown) s")
            return .takeBack(trigger)
        case .no:
            settledAt = time
            switch trigger {
            case .elsewhere:
                elsewhereFactor *= 2
                if elsewhereSince != nil {
                    elsewhereSince  = time
                    workedElsewhere = false
                }
            case .away:
                awayFactor *= 2
                lastInput   = max(lastInput, time)
            case .closed, .locked, .quit:
                break
            }
            cameBack()
            return evaluate(at: time)
        }
    }

    // MARK: Evidence

    /// The person left the lent application at `time`, unless already gone.
    private mutating func leave(at time: Double) {
        if elsewhereSince == nil {
            elsewhereSince  = time
            workedElsewhere = false
        }
        activity = .elsewhere
    }

    /// The person is back with the lent application, unless this evidence predates leaving it again:
    /// false then.
    private mutating func endSpan(at time: Double) -> Bool {
        if let since = elsewhereSince, time < since { return false }
        elsewhereSince  = nil
        workedElsewhere = false
        return true
    }

    /// Input after an away question: present again, wherever they are.
    private mutating func cameBack() {
        if elsewhereSince != nil {
            activity = .elsewhere
        } else if activity == .away {
            activity = .reading
        }
    }

    /// The screen locked or unlocked, the Mac slept or woke. Back in time, nothing happens and the person
    /// is at the Mac again; past the delay, as after a long sleep, the take-back still falls due.
    private mutating func lockChanged(at time: Double) {
        if locked || asleep {
            if lockedSince == nil { lockedSince = time }
        } else if let since = lockedSince, time < since + Self.lockedDelay {
            lockedSince = nil
            lastInput   = max(lastInput, time)
            if elsewhereSince != nil {
                elsewhereSince  = time
                workedElsewhere = false
            }
        }
    }

    // MARK: Decision

    private mutating func evaluate(at time: Double) -> Decision? {
        now = max(now, time)
        guard let due = next(), now >= due.at else { return nil }
        switch due.decision {
        case .ask(let trigger):
            asking    = trigger
            withdrawn = false
            if trigger == .closed { closedAsked = true }
            if trigger == .away { activity = .away }
            reason = describe(trigger)
        case .takeBack(let trigger):
            ended  = true
            asking = nil
            reason = describe(trigger)
        case .withdraw:
            break
        }
        return due.decision
    }

    /// The earliest decision the evidence leads to, and when. A quit ends even an open question; the
    /// lock takes back without asking and, until then, keeps every question back.
    private func next() -> (at: Double, decision: Decision)? {
        guard !held, !ended else { return nil }
        if let quitAt { return (quitAt, .takeBack(.quit)) }
        guard asking == nil else { return nil }
        if let lockedSince { return (lockedSince + Self.lockedDelay, .takeBack(.locked)) }
        if let closedSince, !closedAsked { return (closedSince, .ask(.closed)) }
        if menuOpen { return nil }
        var due = (at: lastInput + delay(of: .away), decision: Decision.ask(.away))
        if let since = elsewhereSince, tuckedSince != nil || workedElsewhere {
            let at = max(since, tuckedSince ?? since) + delay(of: .elsewhere)
            if at < due.at { due = (at, .ask(.elsewhere)) }
        }
        return due
    }

    private func describe(_ trigger: Trigger) -> String {
        let wait = Self.spoken(delay(of: trigger))
        return switch trigger {
        case .elsewhere where tuckedSince != nil:
            "the application stayed hidden or minimized for \(wait) while the person was elsewhere"
        case .elsewhere: "the person worked in another application for \(wait)"
        case .away     : "no input on the Mac for \(wait)"
        case .closed   : "every window of the application was closed"
        case .locked   : "the screen stayed locked or the Mac asleep for \(wait)"
        case .quit     : "the application quit"
        }
    }

    /// `seconds` as the log and the worker read it: "2 min", "30 s".
    public static func spoken(_ seconds: Double) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
            ? "\(Int(seconds / 60)) min"
            : "\(Int(seconds)) s"
    }
}

nonisolated extension LendActivity.Evidence {

    /// What one listener event says, for the lent process `lent`. A click on the menu bar arrives with
    /// another process: the lent application's menus are read from its own notifications instead.
    init(
        _ event: InteractionEvent,
        lent   : Int32
    ) {
        let route: LendActivity.Route = event.processID == lent ? .lent : event.processID > 0 ? .other : .unknown
        switch event.kind {
        case .click, .rightClick, .scroll, .shortcut, .typing, .drag: self = .input(route)
        case .hover: self = .hover(route)
        case .focus: self = .frontmost(route == .lent ? .lent : .other)
        case .gap  : self = .input(.unknown)
        }
    }
}
