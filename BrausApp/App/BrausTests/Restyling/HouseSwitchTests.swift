//
//  HouseSwitchTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseSwitch", .serialized)
@MainActor
struct HouseSwitchTests {

    @Test("The switch is quick: the worker drops into its capsule, then hops out, landing as its room lets it go")
    func timingAndPoses() {
        #expect(HouseSwitch.exit <= HouseSwitch.entryDelay)
        #expect(HouseSwitch.entryDelay + HouseSwitch.hop <= 0.45)
        #expect(HouseSwitch.entryDelay + HouseSwitch.hop == RestylingTiming.roomExit)
        #expect(HouseSwitch.sunk.drop > 0 && HouseSwitch.sunk.scaleX < 1)
        let keys = HouseSwitch.hopKeys
        #expect(keys.first?.time == 0 && keys.last?.time == 1)
        #expect(keys.last?.pose == .rest)
        // Small inside the capsule, then up past its place, then squashed as it lands.
        #expect((keys.first?.pose.drop ?? 0) > 0 && (keys.first?.pose.scaleY ?? 1) < 0.5)
        #expect(keys.contains { $0.pose.drop < 0 && $0.pose.scaleY > 1 })
        #expect(keys.contains { $0.pose.drop == 0 && $0.pose.scaleX > 1 && $0.pose.scaleY < 1 })
    }

    @Test("The hero's worker hops out after the entry delay and drops back in when it leaves")
    func portraitArrivesAndLeaves() throws {
        let view  = try shownPortrait(stage: .present)
        let layer = try #require(view.layer)
        let fade  = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity))
        let rise  = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform))
        let hop   = try #require(rise as? CAKeyframeAnimation)
        #expect(hop.duration == HouseSwitch.hop)
        #expect(hop.values?.count == HouseSwitch.hopKeys.count)
        #expect(fade.beginTime > 0 && fade.beginTime == rise.beginTime)

        view.show(
            portrait(stage: .leaving),
            animated: true
        )
        #expect(layer.opacity == 0)
        #expect(!CATransform3DIsIdentity(layer.transform))
        let out = try #require(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) as? CABasicAnimation)
        #expect(out.duration == HouseSwitch.exit)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) != nil)
    }

    @Test("Under Reduce Motion the hero's worker only fades in and out")
    func portraitOnlyFadesUnderReduceMotion() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let view  = try shownPortrait(stage: .present)
        let layer = try #require(view.layer)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) != nil)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
        view.show(
            portrait(stage: .leaving),
            animated: true
        )
        #expect(layer.opacity == 0)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) != nil)
        #expect(layer.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
    }

    @Test("A portrait outside the hero does not come in or leave")
    func otherPortraitsStayStill() throws {
        let view = try shownPortrait(stage: nil)
        #expect(view.layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.opacity) == nil)
        #expect(view.layer?.animation(forKey: HouseWorkerPortrait.HostView.switchKeys.transform) == nil)
    }

    @Test("Every shape stands in the hero's one portrait height")
    func heroHeightFitsEveryShape() {
        let side = HouseWorkerPortrait.sceneSide(for: HouseHero.workerSize)
        let heights = WorkerShape.allCases.map {
            HouseWorkerPortrait.silhouette(
                of  : $0,
                side: side
            ).boundingRect.height
        }
        #expect(heights.allSatisfy { $0 <= HouseHero.portraitHeight })
        #expect(heights.contains(HouseHero.portraitHeight))
    }

    // MARK: Helpers

    private func portrait(stage: HouseSwitch.Stage?) -> HouseWorkerPortrait {
        HouseWorkerPortrait(
            shape      : .circle,
            status     : .busy,
            size       : HouseHero.workerSize,
            switchStage: stage
        )
    }

    /// A portrait host shown with `stage` and laid out, which starts its arrival.
    private func shownPortrait(stage: HouseSwitch.Stage?) throws -> HouseWorkerPortrait.HostView {
        let view = HouseWorkerPortrait.HostView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 60,
            height: 70
        ))
        view.show(
            portrait(stage: stage),
            animated: false
        )
        view.layoutSubtreeIfNeeded()
        return view
    }
}
