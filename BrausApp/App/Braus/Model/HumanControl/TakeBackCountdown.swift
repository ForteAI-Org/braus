//
//  TakeBackCountdown.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import Foundation

/// TakeBackAnswer is how the question asked before Braus takes an app back ends: the person is done,
/// the person is not, or nobody answered in time.
nonisolated enum TakeBackAnswer: Equatable, Sendable {
    case yes, no, timeout
}

/// TakeBackCountdown counts down the seconds before Braus takes an app back, until the person
/// answers or the time runs out. The first ending stands: an answer after the timeout, or a second
/// answer, changes nothing.
nonisolated struct TakeBackCountdown: Equatable, Sendable {

    private(set) var remaining: Int
    private(set) var answer   : TakeBackAnswer?

    init(seconds: Int) {
        remaining = max(0, seconds)
        answer    = remaining == 0 ? .timeout : nil
    }

    /// One second passed.
    mutating func tick() {
        guard answer == nil else { return }
        remaining -= 1
        if remaining == 0 { answer = .timeout }
    }

    /// The person answered Yes or No.
    mutating func reply(yes: Bool) {
        guard answer == nil else { return }
        answer = yes ? .yes : .no
    }

    /// The line under the question.
    var label: String {
        "Taking it back in \(remaining) s"
    }
}
