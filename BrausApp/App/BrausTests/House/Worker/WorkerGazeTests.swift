//
//  WorkerGazeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Testing
@testable import Braus

@Suite("WorkerGaze", .serialized)
@MainActor
struct WorkerGazeTests {

    private func makeFace(
        status: WorkerStatus = .busy
    ) -> (gaze: WorkerGaze, host: MascotFace.HostView) {
        let host = MascotFace.HostView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 200,
            height: 200
        ))
        host.sphereSize = 100
        host.mascot.status = status
        host.mascot.behave(seed: 7)
        let gaze = WorkerGaze()
        gaze.host = host
        return (gaze, host)
    }

    @Test("The direction is positive to the right and below, and clamps")
    func direction() {
        let face = CGPoint(x: 100, y: 100)
        let right = WorkerGaze.direction(from: face, to: CGPoint(x: 140, y: 100), reach: 100)
        #expect(right.yaw > 0 && right.pitch == 0)
        let below = WorkerGaze.direction(from: face, to: CGPoint(x: 100, y: 40), reach: 100)
        #expect(below.pitch > 0 && below.yaw == 0)
        let far = WorkerGaze.direction(from: face, to: CGPoint(x: -900, y: 900), reach: 100)
        #expect(far.yaw == -1 && far.pitch == -1)
    }

    @Test("A pointer to the right makes the brows look right and pauses the loop")
    func looksAtThePointer() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let (gaze, host) = makeFace()
        #expect(host.mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey) != nil)
        gaze.pointerMoved(toWindow: CGPoint(x: 190, y: 100))
        #expect(host.mascot.isGazing)
        #expect(host.mascot.yaw > 0)
        #expect(host.mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey) == nil)
        gaze.pointerMoved(toWindow: CGPoint(x: 100, y: 10))
        #expect(host.mascot.pitch > 0)
        gaze.pointerMoved(toWindow: CGPoint(x: 10, y: 100))
        #expect(host.mascot.yaw < 0)
    }

    @Test("Leaving waits, then the brows go back to their loop")
    func resumes() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let (gaze, host) = makeFace()
        gaze.pointerMoved(toWindow: CGPoint(x: 190, y: 100))
        gaze.pointerLeft()
        #expect(WorkerGaze.releaseDelay == 0.4)
        #expect(host.mascot.isGazing)
        gaze.pointerLeft(after: 0)
        #expect(!host.mascot.isGazing)
        #expect(host.mascot.yaw == 0 && host.mascot.pitch == 0)
        #expect(host.mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey) != nil)
    }

    @Test("An empty room, a disabled gaze or a pointer beyond the radius looks at nothing")
    func staysStill() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let (gaze, host) = makeFace()
        host.mascot.isAway = true
        gaze.pointerMoved(toWindow: CGPoint(x: 190, y: 100))
        #expect(!host.mascot.isGazing)

        let (off, offHost) = makeFace()
        off.isEnabled = false
        off.pointerMoved(toWindow: CGPoint(x: 190, y: 100))
        #expect(!offHost.mascot.isGazing)

        let (near, nearHost) = makeFace()
        near.radius = 80
        near.pointerMoved(toWindow: CGPoint(x: 100 + 300, y: 100))
        #expect(!nearHost.mascot.isGazing)
        near.pointerMoved(toWindow: CGPoint(x: 100 + 50, y: 100))
        #expect(nearHost.mascot.isGazing)
        near.pointerMoved(toWindow: CGPoint(x: 100 + 300, y: 100))
        near.pointerLeft(after: 0)
        #expect(!nearHost.mascot.isGazing)
    }

    @Test("Reduce Motion makes the brows ignore the pointer")
    func reduceMotion() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = true
        let (gaze, host) = makeFace()
        gaze.pointerMoved(toWindow: CGPoint(x: 190, y: 100))
        #expect(!host.mascot.isGazing)
        #expect(host.mascot.yaw == 0)
    }
}
