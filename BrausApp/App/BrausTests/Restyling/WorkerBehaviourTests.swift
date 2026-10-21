//
//  WorkerBehaviourTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import QuartzCore
import Testing
@testable import Braus

@Suite("WorkerBehaviour", .serialized)
@MainActor
struct WorkerBehaviourTests {

    @Test("The same seed gives the same loop")
    func sameSeed() {
        for status in WorkerStatus.allCases {
            let behaviour = WorkerBehaviour(status)
            #expect(behaviour.loop(seed: 42) == behaviour.loop(seed: 42))
        }
    }

    @Test("Different workers get different loops")
    func differentWorkers() throws {
        let first  = try #require(UUID(uuidString: "6F1C2E0A-3B4D-4E5F-8A9B-0C1D2E3F4A5B"))
        let second = try #require(UUID(uuidString: "6F1C2E0A-3B4D-4E5F-8A9B-0C1D2E3F4A5C"))
        #expect(WorkerBehaviour.seed(for: first) == WorkerBehaviour.seed(for: first))
        #expect(WorkerBehaviour.seed(for: first) != WorkerBehaviour.seed(for: second))
        for status in WorkerStatus.allCases {
            let behaviour = WorkerBehaviour(status)
            let one       = behaviour.loop(seed: WorkerBehaviour.seed(for: first))
            let other     = behaviour.loop(seed: WorkerBehaviour.seed(for: second))
            #expect(one.left != other.left)
            #expect(one.duration != other.duration)
        }
    }

    @Test("Every loop lasts 45 to 90 s, starts and ends at rest, and stays in the brows' ranges")
    func ranges() {
        for status in WorkerStatus.allCases {
            let behaviour = WorkerBehaviour(status)
            let allowed   = Set(behaviour.vocabulary.map(\.action))
            for seed in UInt64(0)..<60 {
                let loop = behaviour.loop(seed: seed)
                #expect(WorkerBehaviour.loopLength.contains(loop.duration))
                #expect(!loop.actions.isEmpty)
                #expect(loop.actions.allSatisfy { allowed.contains($0) })
                for track in [loop.left, loop.right] {
                    #expect(track.first?.time == 0 && track.first?.pose == .rest)
                    #expect(track.last?.time == loop.duration && track.last?.pose == .rest)
                    #expect(track.allSatisfy { $0.pose.isAllowed })
                    let times = track.map(\.time)
                    #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 })
                }
            }
        }
    }

    @Test("No action plays more than maxRepeats times in a row")
    func noLongRuns() {
        for status in WorkerStatus.allCases {
            for seed in UInt64(0)..<60 {
                var run  = 0
                var last : BrowAction?
                for action in WorkerBehaviour(status).loop(seed: seed).actions {
                    run  = action == last ? run + 1 : 1
                    last = action
                    #expect(run <= WorkerBehaviour.maxRepeats)
                }
            }
        }
    }

    @Test("Each status plays its own vocabulary")
    func vocabularies() {
        let busy = Set(WorkerBehaviour(.busy).vocabulary.map(\.action))
        let off  = Set(WorkerBehaviour(.off).vocabulary.map(\.action))
        #expect(busy.contains(.lookAtScreen) && busy.contains(.frown))
        #expect(Set(WorkerBehaviour(.waiting).vocabulary.map(\.action)).isSuperset(of: [.lookAtCamera, .raise, .impatient]))
        #expect(Set(WorkerBehaviour(.free).vocabulary.map(\.action)).isSuperset(of: [.lookLeft, .lookRight, .flick]))
        #expect(off.contains(.sleepBreath) && !off.contains(.flick))
    }

    @Test("The loop runs forever as keyframe animations, additive shifts and turns")
    func animations() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let loop       = WorkerBehaviour(.free).loop(seed: 3)
        let animations = loop.animations(
            for : .left,
            face: 100
        )
        let position = try #require(animations[WorkerBehaviourLoop.positionKey])
        let rotation = try #require(animations[WorkerBehaviourLoop.rotationKey])
        for animation in [position, rotation] {
            #expect(animation.repeatCount == .infinity)
            #expect(animation.isAdditive)
            #expect(animation.duration == loop.duration)
            #expect(animation.values?.count == loop.left.count)
            #expect(animation.keyTimes?.count == loop.left.count)
            #expect(animation.timingFunctions?.count == loop.left.count - 1)
        }
        let shifts = try #require(position.values as? [NSValue]).map(\.pointValue)
        #expect(shifts.allSatisfy { abs($0.x) <= 5 && $0.y >= -4 && $0.y <= 6 })
    }

    @Test("Reduce Motion plays no behaviour")
    func reduceMotion() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        for status in WorkerStatus.allCases {
            #expect(WorkerBehaviour(status).loop(seed: 1).animations(for: .left, face: 100).isEmpty)
        }
        let mascot = makeMascot()
        mascot.status = .busy
        mascot.show(.working, animated: false)
        mascot.behave(seed: 1)
        #expect(mascot.leftBrow.animationKeys() == nil)
        #expect(mascot.rightBrow.animationKeys() == nil)
    }

    @Test("A change of status blends each brow from where it shows, then starts the new loop")
    func blendFromPresentation() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.status = .busy
        mascot.show(.working, animated: false)
        mascot.behave(seed: 9)
        #expect(mascot.behaviour?.status == .busy)

        // Hold the left brow away from rest, as a loop caught mid-action shows it.
        mascot.leftBrow.removeAllAnimations()
        let held: [(String, Any)] = [
            ("position", NSValue(point: CGPoint(x: 3, y: -2))),
            ("transform.rotation.z", 0.1),
        ]
        for (keyPath, value) in held {
            let hold = CABasicAnimation(keyPath: keyPath)
            hold.fromValue  = value
            hold.toValue    = value
            hold.isAdditive = true
            hold.duration   = 1000
            mascot.leftBrow.add(
                hold,
                forKey: "held." + keyPath
            )
        }
        // A window never ordered in still commits the layers, so their presentation shows the hold.
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 100,
                height: 100
            ),
            styleMask  : .borderless,
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.addSublayer(mascot)
        window.displayIfNeeded()
        CATransaction.flush()

        mascot.status = .waiting
        mascot.show(.asking, animated: true)
        mascot.behave(seed: 9)

        #expect(mascot.behaviour?.status == .waiting)
        let shift = try #require(
            mascot.leftBrow.animation(forKey: MascotLayer.blendPositionKey) as? CABasicAnimation
        )
        let turn  = try #require(
            mascot.leftBrow.animation(forKey: MascotLayer.blendRotationKey) as? CABasicAnimation
        )
        let from = try #require(shift.fromValue as? NSValue).pointValue
        #expect(abs(from.x - 3) < 1e-6 && abs(from.y + 2) < 1e-6)
        let angle = try #require(turn.fromValue as? Double)
        #expect(abs(angle - 0.1) < 1e-6)
        #expect(shift.duration == RestylingTiming.browsCalm)

        let loop = try #require(mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey))
        #expect(loop.beginTime >= shift.beginTime + shift.duration - 1e-9)
    }

    @Test("Stopping the behaviour removes its animations")
    func stops() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let mascot = makeMascot()
        mascot.status = .free
        mascot.show(.idle, animated: false)
        mascot.behave(seed: 2)
        #expect(mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey) != nil)
        mascot.behave(seed: nil)
        #expect(mascot.behaviour == nil)
        #expect(mascot.leftBrow.animation(forKey: WorkerBehaviourLoop.positionKey) == nil)
    }

    private func makeMascot() -> MascotLayer {
        let mascot = MascotLayer()
        mascot.frame = CGRect(
            x     : 0,
            y     : 0,
            width : 56,
            height: 56
        )
        return mascot
    }
}
