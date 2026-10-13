//
//  FocusedWindowReading.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

/// FocusedWindowReading is where the internal focus is at the posting boundary
/// of an ordinary window's keys, with an application that did not answer kept
/// apart from one that answered.
///
/// `DialogEndpointResolver.focusedNodeWindowReading(deadlineNanoseconds:)`
/// produces it. A focus that moved and an application too busy to say are
/// opposite facts: the first retires the keys as `focusedNodeChanged`, the
/// second as `focusNotReadable`, and neither sends anything.
nonisolated package enum FocusedWindowReading: Sendable, Equatable {

    /// The focused control names this Window ID.
    case window(Int)

    /// The application answered and there is no window to name: no focused
    /// control, an element without a window, a destroyed element, or any
    /// error other than `.cannotComplete`.
    case noWindow

    /// `.cannotComplete` after the recovery attempt, or the deadline ran out.
    case notResponding
}
