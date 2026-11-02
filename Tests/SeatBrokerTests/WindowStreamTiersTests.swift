//
//  WindowStreamTiersTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import CoreGraphics
import Testing
@testable import SeatBroker

@Suite("Window stream tiers")
struct WindowStreamTiersTests {

    private func window(_ number: Int, _ width: CGFloat, _ height: CGFloat, scale: CGFloat = 2,
                        main: Bool = false, fresh: Bool = false) -> WindowStreamTiers.Window {
        WindowStreamTiers.Window(number: number, size: CGSize(width: width, height: height), viewScale: scale,
                                 isMain: main, isFresh: fresh)
    }

    private func pixels(_ quality: WindowStreamQuality?, _ width: CGFloat, _ height: CGFloat) -> CGSize? {
        quality?.pixelSize(of: CGSize(width: width, height: height))
    }

    @Test func theMainWindowIsCappedTo1080pWithItsAspect() {
        #expect(pixels(WindowStreamTiers.mainQuality(size: CGSize(width: 1150, height: 750), viewScale: 2), 1150, 750)
                == CGSize(width: 1656, height: 1080))
        #expect(pixels(WindowStreamTiers.mainQuality(size: CGSize(width: 750, height: 1150), viewScale: 2), 750, 1150)
                == CGSize(width: 1080, height: 1656))
        #expect(WindowStreamTiers.mainQuality(size: CGSize(width: 1150, height: 750), viewScale: 2).framesPerSecond == 30)
    }

    @Test func aSmallMainWindowKeepsTheViewScaleAndNoneGoesBelowOnePixelPerPoint() {
        #expect(WindowStreamTiers.mainQuality(size: CGSize(width: 800, height: 500), viewScale: 2).scale == 2)
        #expect(WindowStreamTiers.mainQuality(size: CGSize(width: 2560, height: 1440), viewScale: 2).scale == 1)
        #expect(WindowStreamTiers.mainQuality(size: CGSize(width: 1150, height: 750), viewScale: 1).scale == 1)
    }

    @Test func palettesBesideTheMainWindowStayOnTheTopTier() {
        let windows = [window(1, 1150, 750, main: true, fresh: true), window(2, 90, 530), window(3, 420, 160),
                       window(4, 815, 125), window(5, 550, 120, fresh: true)]
        let qualities = WindowStreamTiers.qualities(for: windows)
        for number in 2...5 {
            #expect(qualities[number] == WindowStreamQuality(scale: 2, framesPerSecond: WindowStreamTiers.tiers[0].framesPerSecond))
        }
    }

    @Test func largeSecondariesStepDownToTheFloorsButNeverBelow() {
        let windows = [window(1, 1150, 750, main: true, fresh: true)]
            + (2...9).map { window($0, 1000, 700) }
            + [window(10, 1000, 700, fresh: true)]
        let qualities = WindowStreamTiers.qualities(for: windows)
        #expect(qualities[1] == WindowStreamTiers.mainQuality(size: CGSize(width: 1150, height: 750), viewScale: 2))
        #expect(qualities[10] == WindowStreamQuality(scale: 2, framesPerSecond: WindowStreamTiers.tiers[0].framesPerSecond))
        let lowest = WindowStreamTiers.tiers.last!.framesPerSecond
        for number in 2...9 {
            let quality = try! #require(qualities[number])
            #expect(quality.scale >= 1)
            #expect(quality.framesPerSecond >= lowest)
        }
        #expect((2...9).contains { qualities[$0] != qualities[10] }, "the budget stepped someone down")
    }

    @Test func ofTwoEqualWindowsTheOneFurtherBackStepsDownFirst() {
        // Just over the budget with the main window and two equal secondaries.
        let main = window(1, 1150, 750, main: true)
        let mainCost = Double(1656 * 1080 * 30)
        let side = (WindowStreamTiers.pixelRateBudget - mainCost) / 2 / Double(WindowStreamTiers.tiers[0].framesPerSecond) / 4 + 1
        let width = side.squareRoot().rounded(.up)
        let qualities = WindowStreamTiers.qualities(for: [main, window(2, width, width), window(3, width, width)])
        #expect(qualities[2]?.framesPerSecond == WindowStreamTiers.tiers[0].framesPerSecond)
        #expect(qualities[3]?.framesPerSecond == WindowStreamTiers.tiers[1].framesPerSecond)
    }

    @Test func manyPalettesStepDownInFrameRateToStayInTheFrameBudget() {
        let windows = [window(1, 1150, 750, main: true, fresh: true)]
            + (2...WindowStreamTiers.streamLimit).map { window($0, 420, 160) }
        let qualities = WindowStreamTiers.qualities(for: windows)
        let frames = qualities.values.reduce(0) { $0 + $1.framesPerSecond }
        #expect(frames <= WindowStreamTiers.frameRateBudget)
        #expect(qualities[2]?.framesPerSecond == WindowStreamTiers.tiers[0].framesPerSecond, "the front one stays")
        #expect(qualities[WindowStreamTiers.streamLimit]?.framesPerSecond != WindowStreamTiers.tiers[0].framesPerSecond)
        #expect(qualities.values.allSatisfy { $0.scale >= 1 })
    }

    @Test func aWindowThatClosesGivesTheOthersTheirTierBack() {
        let many = [window(1, 1150, 750, main: true)] + (2...10).map { window($0, 600, 400) }
        let few = Array(many.prefix(2))
        #expect(WindowStreamTiers.qualities(for: few)[2]?.scale == 2)
        #expect(WindowStreamTiers.qualities(for: many)[10]?.scale != 2)
    }
}
