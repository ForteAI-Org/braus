//
//  ControlToggle.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import Foundation

/// ControlToggle decides what one press of ⌃⌥Tab does: take control of the worker's application
/// while the worker holds it, or hand it back while the person holds it. A press acts only at rest,
/// once the previous handover has really completed; during any transition it is ignored, with the
/// reason. Pure: it reads a `State` built from the human control and the companion, never a timer.
nonisolated enum ControlToggle {

    enum Action: Equatable {

        /// As clicking Take Control.
        case takeControl

        /// As End Control, then Yes, on the worker in the corner.
        case handBack
    }

    enum Decision: Equatable {
        case act(Action)
        case ignore(String)
    }

    /// One worker's handover as it is now.
    struct State: Equatable {

        /// The worker's seat holds an application with a screen to watch.
        var holdsApplication = false

        /// The human control: taken or blocked and not finished, as End Control shows; finishing,
        /// blocked, or refused its lend.
        var isUnderway  = false
        var isFinishing = false
        var isBlocked   = false
        var isRefused   = false

        /// The application reached the person's screen, and its still has landed on it.
        var isLent    = false
        var hasLanded = false

        /// The worker in the corner can still be answered Yes: no hand-back was asked yet.
        var asksHandBack = false

        /// The screen window still plays the hand-back's curtain.
        var isHandingBack = false

        /// That curtain says Braus is reading what the person did, until the report is made.
        var isReadingHandBack = false

        /// A worker the key is for: it holds an application, or a handover of one is under way.
        var isCandidate: Bool { holdsApplication || isUnderway || isFinishing || isHandingBack }
    }

    static func decide(_ state: State) -> Decision {
        if state.isReadingHandBack { return .ignore("Braus is reading what the person did") }
        if state.isHandingBack { return .ignore("the hand-back curtain is still playing") }
        if state.isFinishing { return .ignore("the final read and the report are under way") }
        guard state.isUnderway else {
            return state.holdsApplication ? .act(.takeControl) : .ignore("the worker holds no application")
        }
        if state.isBlocked { return .ignore("control is paused by a failure") }
        if state.isRefused { return .ignore("the application could not be lent") }
        if !state.isLent { return .ignore("the worker's step is draining or the application is on its way") }
        if !state.hasLanded { return .ignore("the application is still landing on the person's screen") }
        if !state.asksHandBack { return .ignore("the hand-back was already asked") }
        return .act(.handBack)
    }

    /// Whether help may name the key for a worker in `state`: only where a press would act, never while
    /// VoiceOver runs and the key is unregistered. The landing, which no view observes, counts as done.
    static func namesKey(
        _ state  : State,
        voiceOver: Bool
    ) -> Bool {
        var landed = state
        landed.hasLanded    = state.hasLanded || state.isLent
        landed.asksHandBack = state.asksHandBack || state.isLent
        guard !voiceOver, case .act = decide(landed) else { return false }
        return true
    }

    /// The worker a press is for, among the workers that hold an application or have one lent:
    /// the only one; else the only one whose application is lent or on its way; else the one whose
    /// screen window is frontmost. Nil, with the reason, when none can be told apart.
    static func target(
        among states: [UUID: State],
        frontmost   : UUID?
    ) -> (workerID: UUID?, reason: String) {
        let candidates = states.filter(\.value.isCandidate)
        if candidates.isEmpty { return (nil, "no worker holds an application") }
        if candidates.count == 1 { return (candidates.keys.first, "the only worker with an application") }
        let underway = candidates.filter { $0.value.isUnderway || $0.value.isFinishing || $0.value.isHandingBack }
        if underway.count == 1 { return (underway.keys.first, "the worker whose application is lent") }
        if let frontmost, candidates[frontmost] != nil { return (frontmost, "the worker whose screen window is in front") }
        return (nil, "\(candidates.count) workers hold an application and none of their screen windows is in front")
    }
}
