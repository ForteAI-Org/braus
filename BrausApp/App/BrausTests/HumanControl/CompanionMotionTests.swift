//
//  CompanionMotionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import Braus

@Suite("CompanionMotion")
@MainActor
struct CompanionMotionTests {

    typealias Layout = HumanControlLayout

    // Workers' own seeds: a step of the generator's increment would replay one sequence shifted.
    private static let seeds: [UInt64] = (0..<40).map {
        WorkerBehaviour.seed(for: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0)) ?? UUID())
    }

    @Test("Each reaction's body, brows and figure start and end at rest, in time, within their limits", arguments: [
        CompanionReaction.yes,
        CompanionReaction.no,
    ])
    func reactionTracks(reaction: CompanionReaction) throws {
        let body = reaction.action.keys
        #expect(body.first?.time == 0 && body.last?.time == reaction.duration)
        #expect(body.first?.pose == .rest && body.last?.pose == .rest)
        #expect(zip(body, body.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(body.allSatisfy { $0.pose.isAllowed })

        let brows = reaction.keys
        #expect(brows.first?.time == 0 && brows.last?.time == reaction.duration)
        #expect(brows.first?.left == .rest && brows.last?.left == .rest)
        #expect(brows.first?.right == .rest && brows.last?.right == .rest)
        #expect(zip(brows, brows.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(brows.allSatisfy { $0.left.isAllowed && $0.right.isAllowed })

        let figure = reaction.figure
        #expect(figure.first?.time == 0 && figure.last?.time == reaction.duration)
        #expect(figure.first?.pose == .rest && figure.last?.pose == .rest)
        #expect(zip(figure, figure.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(figure.allSatisfy { $0.pose.isAllowed })
        #expect(reaction.duration <= 1.4, "snappy")
    }

    @Test("Yes nods, crouches and hops with its whole figure; No rocks its head both ways and laughs three times")
    func figureShapes() {
        let yes = CompanionReaction.yes.figure.map(\.pose)
        #expect(yes.filter { $0.height < 0 }.count >= 3, "two nods and a crouch squash it")
        #expect(yes.contains { $0.dy >= 0.15 && $0.height > 0 }, "the hop rises stretched")
        let no = CompanionReaction.no.figure.map(\.pose)
        #expect(no.filter { $0.turn > 0 }.count == 2 && no.filter { $0.turn < 0 }.count == 2, "rocks twice each way")
        #expect(no.filter { $0.height < 0 }.count == 3, "three laughs")

        // The buttons are left of the worker: it leans toward Yes and tilts its head away from No.
        let eager   = CompanionReaction.lean(yes: true)
        let puzzled = CompanionReaction.lean(yes: false)
        #expect(eager.isAllowed && puzzled.isAllowed)
        #expect(eager.turn > 0 && eager.dx < 0 && eager.height > 0)
        #expect(puzzled.turn < 0 && puzzled.height < 0)
    }

    @Test("A brow that moves carries its contact shadow, so it never lifts off the face")
    func browsCarryTheirShadow() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let mascot = MascotLayer()
        mascot.frame = CGRect(
            x     : 0,
            y     : 0,
            width : Layout.sphere,
            height: Layout.sphere
        )
        mascot.layoutIfNeeded()
        mascot.behave(seed: Self.seeds[0])
        mascot.holdBrows(
            from: (left: .rest, right: .rest),
            to  : CompanionReaction.hover(yes: false)
        )
        mascot.playBrows(
            CompanionReaction.yes.keys,
            duration: CompanionReaction.yes.duration
        )
        for brow in [mascot.leftBrow, mascot.rightBrow] {
            let moves   = Set(brow.animationKeys() ?? [])
            let carried = Set(mascot.contact(of: brow).animationKeys() ?? [])
            #expect(moves.count >= 4, "the loop, the hold and the reaction move the brow")
            #expect(moves.isSubset(of: carried), "\(moves.subtracting(carried))")
        }
    }

    @Test("Yes nods, hops and looks done; No shakes its head and chuckles with relaxed brows")
    func reactionShapes() {
        let yes = CompanionReaction.yes.action.keys.map(\.pose)
        #expect(CompanionReaction.yes.brows == .done)
        #expect(yes.contains { $0.lean > 0 } && yes.contains { $0.hop > 0 })
        let no = CompanionReaction.no.action.keys.map(\.pose)
        #expect(CompanionReaction.no.brows == .idle)
        #expect(no.filter { $0.tilt > 0 }.count == 2 && no.filter { $0.tilt < 0 }.count == 2, "shakes twice")
        #expect(no.filter { $0.stretch < 0 }.count == 3, "three bobs of a chuckle")
        for yes in [true, false] {
            let held = CompanionReaction.hover(yes: yes)
            #expect(held.left.isAllowed && held.right.isAllowed)
            #expect(held.left.dy > 0, "lifted over either answer")
        }
        let asking = CompanionReaction.hover(yes: false)
        #expect(asking.left.dy > asking.right.dy, "one brow up")
    }

    @Test("The reactions take only poses the hero's actions take, so the room bakes no new frame")
    func reactionsBakeNothingNew() {
        let turn: [WorkerAction] = [.reading, .thinking, .working, .replying]
        let known = Set(turn.flatMap { $0.keys.map(\.pose) })
        for reaction in CompanionReaction.allCases {
            #expect(Set(reaction.action.keys.map(\.pose)).isSubset(of: known), "\(reaction)")
        }
    }

    @Test("The watching vocabulary ponders and chuckles at their weights, among the looks, checks and nods")
    func watchingVocabulary() {
        let entries = WorkerBehaviour.watching.vocabulary
        let weights = Dictionary(uniqueKeysWithValues: entries.map { ($0.action, $0.weight) })
        #expect(weights[.ponder] == 1.2)
        #expect(weights[.chuckle] == 0.5)
        for action in [BrowAction.lookAround, .lookLeft, .lookRight, .lookUp, .checkWork, .nod] {
            #expect(weights[action] != nil, "\(action)")
        }
        #expect(WorkerBehaviour.watching.status == .free)
        #expect(weights[.chuckle] ?? 0 < weights[.ponder] ?? 0, "chuckling is the rarest")
    }

    @Test("The watching loop is seeded, lasts as every loop does, and never repeats an action too often")
    func watchingLoop() {
        var ponders  = 0
        var chuckles = 0
        for seed in Self.seeds {
            let loop = WorkerBehaviour.watching.loop(seed: seed)
            #expect(loop == WorkerBehaviour.watching.loop(seed: seed), "reproducible from the seed")
            #expect(WorkerBehaviour.loopLength.contains(loop.duration))
            #expect(loop.spans.count == loop.actions.count)
            #expect(zip(loop.spans, loop.spans.dropFirst()).allSatisfy { $0.start + $0.duration <= $1.start })
            #expect(loop.spans.allSatisfy { $0.start + $0.duration <= loop.duration })
            var run = 0
            var last: BrowAction?
            for action in loop.actions {
                run  = action == last ? run + 1 : 1
                last = action
                #expect(run <= WorkerBehaviour.maxRepeats)
            }
            for intent in loop.intents {
                #expect(intent.keys.first?.pose == .rest && intent.keys.last?.pose == .rest)
                #expect(intent.keys.allSatisfy { $0.pose.isAllowed })
            }
            for track in [loop.left, loop.right] {
                #expect(track.first?.pose == .rest && track.last?.pose == .rest)
                #expect(track.allSatisfy { $0.pose.isAllowed })
            }
            ponders  += loop.actions.filter { $0 == .ponder }.count
            chuckles += loop.actions.filter { $0 == .chuckle }.count
        }
        #expect(ponders > chuckles && chuckles > 0, "\(ponders) ponders, \(chuckles) chuckles")
    }

    @Test("The watching loop's body takes no more poses than a room bakes, so no gesture is left out")
    func watchingPosesFit() {
        var poses = Set<BodyPose>()
        for seed in Self.seeds {
            for intent in WorkerBehaviour.watching.loop(seed: seed).intents {
                poses.formUnion(intent.keys.map(\.pose).filter { $0 != .rest })
            }
        }
        #expect(poses.count <= RoomBodyMotion.maxPoses, "\(poses.count) poses")
    }

    @Test("The showcase ponders or chuckles within its first seconds")
    func showcaseStartsAtOnce() throws {
        let loop  = WorkerBehaviour.showcase.loop(seed: 42)
        let first = try #require(loop.spans.first)
        #expect(first.start <= 1.2)
        #expect(Set(loop.actions).isSubset(of: [.ponder, .chuckle]))
        #expect(loop.actions.contains(.ponder) && loop.actions.contains(.chuckle))
    }

    @Test("The thought bubble shows only while the loop ponders, and fades before each ponder ends")
    func thoughtSchedule() {
        for seed in Self.seeds.prefix(12) {
            let loop    = WorkerBehaviour.watching.loop(seed: seed)
            let windows = ThoughtBubble.windows(in: loop)
            let ponders = zip(loop.actions, loop.spans).filter { $0.0 == .ponder }.map(\.1)
            #expect(windows == ponders)
            let parts: [ThoughtBubble.Part] = [.circle(0), .circle(1), .circle(2), .cloud, .dot(0), .dot(1), .dot(2)]
            for rises in [true, false] {
                for part in parts {
                    let keys = ThoughtBubble.keys(
                        of      : part,
                        windows : windows,
                        duration: loop.duration,
                        rises   : rises
                    )
                    #expect(keys.first?.time == 0 && keys.last?.time == loop.duration)
                    #expect(zip(keys, keys.dropFirst()).allSatisfy { $0.time <= $1.time })
                    for key in keys where key.opacity > 0 {
                        #expect(windows.contains { key.time > $0.start && key.time < $0.start + $0.duration })
                    }
                    if !rises { #expect(keys.allSatisfy { $0.rise == 0 }, "nothing rises under Reduce Motion") }
                }
            }
        }
    }

    @Test("The thought bubble never shows over an open question, and sits clear of the balloon in the panel")
    func thoughtsClearOfTheQuestion() {
        #expect(ThoughtBubble.shows(isAsking: false, isGazing: false, isLeaving: false))
        #expect(!ThoughtBubble.shows(isAsking: true, isGazing: false, isLeaving: false))
        #expect(!ThoughtBubble.shows(isAsking: false, isGazing: true, isLeaving: false))
        #expect(!ThoughtBubble.shows(isAsking: false, isGazing: false, isLeaving: true))

        let panel  = CGRect(origin: .zero, size: Layout.panelSize)
        let pieces = [Layout.thoughtCloud] + Layout.thoughtCircles.map {
            CGRect(
                x     : $0.centre.x - $0.radius,
                y     : $0.centre.y - $0.radius,
                width : 2 * $0.radius,
                height: 2 * $0.radius
            )
        }
        for height in [Layout.questionHeight, Layout.countdownHeight] {
            let balloon = Layout.balloonFrame(height: height)
            for piece in pieces {
                #expect(panel.contains(piece))
                #expect(!piece.intersects(balloon))
                #expect(piece.minY >= Layout.mascotCell.maxY, "above the worker's head")
            }
        }
        for (index, piece) in pieces.enumerated() {
            for other in pieces.dropFirst(index + 1) {
                #expect(!piece.intersects(other), "\(piece) and \(other)")
            }
        }
    }

    @Test("Over Yes or No the worker looks at the button's centre", arguments: [false, true])
    func gazeAtTheButton(countdown: Bool) {
        let balloon = Layout.balloonFrame(height: countdown ? Layout.countdownHeight : Layout.questionHeight)
        let buttons = Layout.buttonFrames(under: balloon)
        #expect(Layout.gazeTarget(yes: true, under: balloon) == CGPoint(x: buttons.yes.midX, y: buttons.yes.midY))
        #expect(Layout.gazeTarget(yes: false, under: balloon) == CGPoint(x: buttons.no.midX, y: buttons.no.midY))
    }
}
