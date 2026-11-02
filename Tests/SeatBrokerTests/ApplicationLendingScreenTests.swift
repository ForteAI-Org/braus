//
//  ApplicationLendingScreenTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
@testable import SeatBroker
@testable import SeatSession
import Testing

@MainActor
@Suite("Lending display selection")
struct ApplicationLendingScreenTests {
    private let builtIn = PersonScreen.Screen(displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isSeat: false)
    // WindowServer (1512, 317, 1920, 1080), expressed in AppKit's bottom-left space.
    private let external = PersonScreen.Screen(displayID: 2,
        frame: CGRect(x: 1512, y: -415, width: 1920, height: 1080), isSeat: false)
    private let seat = PersonScreen.Screen(displayID: 3,
        frame: CGRect(x: 3432, y: 0, width: 1920, height: 1080), isSeat: true)

    @Test func pointerOnExternalCentresTheLentGroupThere() throws {
        let chosen = try #require(PersonScreen.chosen(among: [builtIn, external, seat],
            pointer: CGPoint(x: 2000, y: 200), keyWindowDisplay: builtIn.displayID))
        #expect(chosen == external)
        let visible = ApplicationLendingScreen.windowServerFrame(
            visibleFrame: CGRect(x: 1512, y: -415, width: 1920, height: 1056),
            menuBarFrame: builtIn.frame)
        #expect(visible == CGRect(x: 1512, y: 341, width: 1920, height: 1056))
        let frames = [CGRect(x: 4000, y: 100, width: 600, height: 400),
                      CGRect(x: 4700, y: 250, width: 300, height: 200)]
        let layout = ApplicationLendingLayout(frames: frames, visibleFrame: visible)
        let group = layout.frames.reduce(CGRect.null) { $0.union($1) }
        #expect(group.midX == visible.midX)
        #expect(group.midY == visible.midY)
        #expect(layout.frames[1].minX - layout.frames[0].minX == 700)
        #expect(layout.frames[1].minY - layout.frames[0].minY == 150)
        #expect(layout.frames.map(\.size) == frames.map(\.size))
        #expect(!layout.wasClamped)
    }

    @Test func missingPointerFallsBackToKeyWindowThenMenuBar() {
        #expect(PersonScreen.chosen(among: [builtIn, external, seat],
            pointer: nil, keyWindowDisplay: external.displayID) == external)
        #expect(PersonScreen.chosen(among: [builtIn, external, seat],
            pointer: CGPoint(x: -9000, y: 9000), keyWindowDisplay: nil) == builtIn)
    }

    @Test func virtualScreensAreExcludedFromEveryFallback() {
        #expect(PersonScreen.chosen(among: [seat, builtIn, external],
            pointer: CGPoint(x: 3500, y: 200), keyWindowDisplay: external.displayID) == external)
        #expect(PersonScreen.chosen(among: [seat, builtIn, external],
            pointer: CGPoint(x: 3500, y: 200), keyWindowDisplay: seat.displayID) == builtIn)
        #expect(PersonScreen.chosen(among: [seat], pointer: nil, keyWindowDisplay: seat.displayID) == nil)
    }

    @Test func seatIdentityRequiresBothVendorAndModel() {
        #expect(PersonScreen.isSeat(vendor: 0xF0A7, model: 0xA617))
        #expect(!PersonScreen.isSeat(vendor: 0xF0A7, model: 1))
        #expect(!PersonScreen.isSeat(vendor: 1, model: 0xA617))
    }

    @Test func mainVisibleFrameConversionRetainsMenuAndDockInsets() {
        #expect(ApplicationLendingScreen.windowServerFrame(
            visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 880), menuBarFrame: builtIn.frame)
            == CGRect(x: 0, y: 32, width: 1512, height: 880))
    }
}
