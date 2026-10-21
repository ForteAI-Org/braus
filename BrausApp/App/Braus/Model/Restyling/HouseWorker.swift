//
//  HouseWorker.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// HouseWorker is one worker as the house shows it: one of the mockup's simulated workers, or one of the
/// team's real ones as `HouseRoster` reads it.
///
/// `activity` is what the worker is doing, or needs from you, while it works or waits, in plain
/// words; `role` is what it does, in a few words. Every mock worker has both, so a worker shown in any
/// state never reads as a status word. `usesScreen` is whether the worker has a screen in front of it,
/// an app it drives, which lights its room from the front. A real worker also carries `needsSetup`
/// and the label its team row is read with (`spokenLabel`); a mock one leaves both unset.
nonisolated struct HouseWorker: Identifiable, Sendable {
    let id         : UUID
    var name       : String
    var status     : WorkerStatus
    var activity   : String
    var role       : String
    var category   : AppCategory
    var shape      : WorkerShape
    var badge      : HouseBadge?
    var usesScreen : Bool
    var needsSetup : Bool = false
    var spokenLabel: String?

    /// The worker's description in the conversation and accessibility labels: what it is doing or needs while busy or waiting,
    /// otherwise its role, or "Needs Setup" while it has no model. Never a status word, which the room's light already shows.
    var subtitle: String {
        switch status {
        case .busy, .waiting      : activity
        case .off where needsSetup: TeamRow.toConfigure
        case .free, .off          : role
        }
    }
}
