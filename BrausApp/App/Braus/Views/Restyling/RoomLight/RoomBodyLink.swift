//
//  RoomBodyLink.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import QuartzCore

/// RoomBodyLink joins a room's renderer and the brows over the body it draws, which SwiftUI builds
/// apart: the brows tell it the loop they play and when it started, the room moves the body in step
/// with that loop and moves the brows with the body.
///
/// It holds both weakly and the loop by value, so either side may arrive first.
@MainActor
final class RoomBodyLink {

    /// The room that draws the body; setting it gives the room the loop playing now.
    weak var room: RoomLightView? {
        didSet {
            guard room !== oldValue else { return }
            room?.bodyLink = self
            room?.bodyLoopDidChange()
        }
    }

    /// The brows over the body.
    weak var mascot: MascotLayer?

    /// The loop the brows play, and when it started on the host clock.
    private(set) var loop : WorkerBehaviourLoop?
    private(set) var start: CFTimeInterval = 0

    /// Records the loop `mascot` plays now and lets the room follow it when it changed.
    func browsDidBehave(_ mascot: MascotLayer) {
        self.mascot = mascot
        guard mascot.behaviour != loop || mascot.behaviourStart != start else { return }
        loop  = mascot.behaviour
        start = mascot.behaviourStart
        room?.bodyLoopDidChange()
    }
}
