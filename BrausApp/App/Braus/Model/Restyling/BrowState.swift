//
//  BrowState.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// BrowState is the expression a mascot's brows hold. Raw values are the prototype's outline keys.
nonisolated enum BrowState: String, CaseIterable, Codable, Sendable {
    case idle      = "IDLE"
    case look      = "LOOK"
    case listening = "LISTENING"
    case working   = "WORKING"
    case asking    = "ASKING"
    case done      = "DONE"
    case failed    = "FAILED"
    case offline   = "OFFLINE"

    /// The expression that shows a worker's status.
    init(_ status: WorkerStatus) {
        switch status {
        case .busy   : self = .working
        case .free   : self = .idle
        case .waiting: self = .asking
        case .off    : self = .offline
        }
    }
}
