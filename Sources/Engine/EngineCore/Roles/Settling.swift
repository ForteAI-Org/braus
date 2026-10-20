//
//  Settling.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import Foundation

/// Settling is the wait between a delivered gesture and the perception that judges it, ended as
/// soon as the target's window has settled and never later than `cap`.
///
/// The cap is the engine's fixed pause, and it stays the engine's: the role only decides whether
/// the window says it is done sooner. A conformer that has nothing to watch (no running stream,
/// another window) waits the whole cap, and an engine given no settling role sleeps the cap
/// itself, which is the behaviour before this role existed. It never throws and never sends input.
///
/// A conformer that compares what the window shows after a gesture with what it showed before it
/// takes its reference in `prepare`, which the engine calls right before it delivers a gesture.
///
/// It answers how the wait ended (`SettleResult`). The engine judges by perceiving again either way;
/// a wait that ended at the cap with the window still busy makes a verdict of no effect unknown,
/// since the effect may still be on its way.
public protocol Settling: Sendable {

    /// Notes what the window of `processID` shows now, right before a gesture is delivered, for
    /// the next `settle` to compare with. Never throws; a conformer with nothing to note returns.
    func prepare(in processID: pid_t) async

    /// Returns once the window of `processID` has settled after the last gesture, or at `cap`, and
    /// answers which.
    @discardableResult
    func settle(in processID: pid_t, cap: Duration) async -> SettleResult
}

/// SettleResult is how a wait after a gesture ended, as the settling role measured it.
public enum SettleResult: String, Sendable, Equatable {

    /// What the role watches held still before the cap: what is read next is what the gesture has
    /// left so far.
    case settled

    /// The cap came while what the role watches was still changing, or with something still on its
    /// way (a request in flight): what is read next may not be what the gesture leaves.
    case capped

    /// The role had nothing to watch, and waited out the cap.
    case unavailable
}

extension Settling {

    /// A conformer that keeps no reference before a gesture has nothing to do here.
    public func prepare(in processID: pid_t) async {}
}
