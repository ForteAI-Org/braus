//
//  RoomBodyLink.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import QuartzCore

/// RoomBodyLink joins a room's renderer and the brows over the body it draws, which SwiftUI builds
/// apart: the brows tell it the loop they play and when it started, the room moves the body in step
/// with that loop and moves the brows with the body. At the top of a conversation it also carries
/// the body's action through a turn (`act(_:)`), which takes the loop's place.
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

    /// What the body does in place of the brows' loop, at the top of a conversation, and when it
    /// started on the host clock; nil for the loop.
    private(set) var action     : WorkerAction?
    private(set) var actionStart: CFTimeInterval = 0

    /// Whether the body may take an action, so the room bakes every action's poses ahead.
    private(set) var takesActions = false

    /// Gives the body `action` from now, or its loop again with nil; the room cross-fades to it.
    func act(_ action: WorkerAction?) {
        takesActions = true
        guard action != self.action else { return }
        self.action = action
        actionStart = CACurrentMediaTime()
        room?.bodyActionDidChange()
    }

    /// Records the loop `mascot` plays now and lets the room follow it when it changed.
    func browsDidBehave(_ mascot: MascotLayer) {
        self.mascot = mascot
        guard mascot.behaviour != loop || mascot.behaviourStart != start else { return }
        loop  = mascot.behaviour
        start = mascot.behaviourStart
        room?.bodyLoopDidChange()
    }
}
