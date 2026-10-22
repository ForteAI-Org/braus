//
//  WorkerStatus.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// WorkerStatus is what a worker is doing, as its room's status light shows it.
nonisolated enum WorkerStatus: CaseIterable, Sendable {
    case busy, free, waiting, off

    /// The light's colour, components in 0...1. A worker that is off has no light.
    var light: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .busy   : (red: 255.0 / 255, green: 176.0 / 255, blue: 72.0 / 255)
        case .free   : (red: 48.0 / 255,  green: 209.0 / 255, blue: 88.0 / 255)
        case .waiting: (red: 120.0 / 255, green: 170.0 / 255, blue: 1)
        case .off    : nil
        }
    }

    /// How strongly the light shines, in 0...1.
    var lightStrength: Double {
        switch self {
        case .busy   : 1
        case .free   : 0.5
        case .waiting: 0.9
        case .off    : 0
        }
    }
}
