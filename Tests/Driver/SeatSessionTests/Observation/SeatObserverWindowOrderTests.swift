//
//  SeatObserverWindowOrderTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/10/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The observer's window order checks run every third sample and share one
/// window list: a sample asks the sensing for the combined reading once.
@Suite("Seat observer window order")
@MainActor
struct SeatObserverWindowOrderTests {

    @Test("a target that started behind asks one combined reading per third sample")
    func oneReadingForBothChecks() {
        let sensing = FakeSensing()
        sensing.isBehind   = true
        sensing.orderIndex = 3

        let observer = SeatObserver(
            target                    : FakeGeometry.adoptedWindow,
            expectedFrontmostProcessID: FakeGeometry.userPID,
            baselineCursor            : .zero,
            sensing                   : sensing
        )
        #expect(observer.targetStartedBehindUserApp == true)

        _ = observer.observation()
        _ = observer.observation()
        #expect(sensing.windowOrderReadCount == 0)

        sensing.isBehind   = false
        sensing.orderIndex = 4
        let observation = observer.observation()

        #expect(sensing.windowOrderReadCount == 1)
        #expect(sensing.lastWindowOrderProcessID == FakeGeometry.userPID)
        #expect(observation.windowOrderChanged)
        #expect(observation.targetMovedAheadOfUserApp)
    }

    @Test("a target that did not start behind asks only for the order index")
    func noRelationWhenNotBehind() {
        let sensing = FakeSensing()
        sensing.isBehind = false

        let observer = SeatObserver(
            target                    : FakeGeometry.adoptedWindow,
            expectedFrontmostProcessID: FakeGeometry.userPID,
            baselineCursor            : .zero,
            sensing                   : sensing
        )
        _ = observer.observation()
        _ = observer.observation()
        let observation = observer.observation()

        #expect(sensing.windowOrderReadCount == 1)
        #expect(sensing.lastWindowOrderProcessID == nil)
        #expect(!observation.windowOrderChanged)
        #expect(!observation.targetMovedAheadOfUserApp)
    }
}
