//
//  MockWorker.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// MockWorker is one worker of the mockup's simulated house.
nonisolated struct MockWorker: Identifiable, Sendable {
    let id        : UUID
    var name      : String
    var status    : WorkerStatus
    var activity  : String
    var category  : AppCategory
    var appearance: WorkerAppearance
    var badge     : MockBadge?
}
