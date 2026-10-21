//
//  MockWorker.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// MockWorker is one worker of the mockup's simulated house.
///
/// `activity` is what the worker is doing, or needs from you, while it works or waits, in plain
/// words; `role` is what it does, in a few words. Every mock worker has both, so a worker shown in any
/// state never reads as a status word.
nonisolated struct MockWorker: Identifiable, Sendable {
    let id      : UUID
    var name    : String
    var status  : WorkerStatus
    var activity: String
    var role    : String
    var category: AppCategory
    var shape   : WorkerShape
    var badge   : MockBadge?

    /// The line under the worker's name in a row: what it is doing or needs while busy or waiting,
    /// otherwise its role. Never a status word, which the room's light already shows.
    var subtitle: String {
        switch status {
        case .busy, .waiting: activity
        case .free, .off    : role
        }
    }
}
