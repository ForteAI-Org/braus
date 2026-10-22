//
//  RestylingTiming.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// RestylingTiming is the design's motion table, in seconds.
nonisolated enum RestylingTiming {
    static let ringBuildFirst: Double = 2.0
    static let ringBuildLater: Double = 0.45
    static let dotsGlow      : Double = 1.35
    static let preparation   : Double = 0.55
    static let zoneTravel    : Double = 0.5
    static let zoneSpread    : Double = 0.55
    static let taskWindowGrow: Double = 0.6
    static let toMenuBar     : Double = 0.48
    static let fromMenuBar   : Double = 0.52
    static let sendFlight    : Double = 0.56
    static let quoteFlight   : Double = 0.52
    static let browsCalm     : Double = 0.36
    static let browsDecisive : Double = 0.23
    static let browStagger   : Double = 0.04
    static let roomFlicker   : Double = 3.4
    static let waitingBreath : Double = 2.2
    static let headBreath    : Double = 6.5

    /// The delay between one word of a reply fading in and the next.
    static let wordStagger   : Double = 0.045

    /// How long a chosen worker takes to step out of its room toward the chat, and to step back in;
    /// its plaque drops in once it is out, and what follows in the chat can start from it.
    static let roomExit      : Double = 0.45

    /// How long a plaque takes to fade when its worker comes back, before the worker steps in.
    static let plaqueLeave   : Double = 0.2
}
