//
//  PersonScreenTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import SeatBroker
import Testing

@Suite("PersonScreen")
struct PersonScreenTests {

    /// The built-in screen with the menu bar, an external one to its right, and a Seat's virtual
    /// display beyond it, in `NSScreen.screens`' order.
    private let builtIn  = screen(1, x: 0, y: 0, width: 1512, height: 982)
    private let external = screen(2, x: 1512, y: -200, width: 2560, height: 1440)
    private let seat     = screen(3, x: 4072, y: 0, width: 2560, height: 1440, isSeat: true)

    private let onSeat = CGPoint(x: 5000, y: 700)

    @Test("The screen under the pointer wins over the key window's and the main one")
    func pointerFirst() {
        #expect(chosen(pointer: CGPoint(x: 2000, y: 600), key: builtIn.displayID) == external)
    }

    @Test("A pointer on a screen's top or right edge is on that screen")
    func edgesIncluded() {
        #expect(chosen(pointer: CGPoint(x: 3000, y: 1240)) == external)
        #expect(chosen(pointer: CGPoint(x: 1512, y: 982)) == builtIn, "the first of two screens sharing an edge")
    }

    @Test("Without a pointer on a person's screen, the key window's screen, then the main one")
    func fallbacks() {
        #expect(chosen(pointer: onSeat, key: external.displayID) == external)
        #expect(chosen(pointer: nil, key: external.displayID) == external)
        #expect(chosen(pointer: onSeat) == builtIn)
        #expect(chosen(pointer: nil, key: 99) == builtIn)
    }

    @Test("A Seat's display is never chosen, not even under the pointer or Braus' key window")
    func seatNeverChosen() {
        #expect(chosen(pointer: onSeat, key: seat.displayID) == builtIn)
        #expect(chosen(among: [seat, external], pointer: nil) == external)
        #expect(chosen(among: [seat], pointer: onSeat, key: seat.displayID) == nil)
        #expect(chosen(among: [], pointer: nil) == nil)
    }

    @Test("A Seat's display is known by the identity the Seat gives every virtual display")
    func seatIdentity() {
        #expect(PersonScreen.isSeat(vendor: 0xF0A7, model: 0xA617))
        #expect(!PersonScreen.isSeat(vendor: 0x0610, model: 0xA050), "a built-in panel")
        #expect(!PersonScreen.isSeat(vendor: 0xF0A7, model: 0x0001))
    }

    private func chosen(
        among screens: [PersonScreen.Screen]? = nil,
        pointer      : CGPoint?,
        key          : CGDirectDisplayID? = nil
    ) -> PersonScreen.Screen? {
        PersonScreen.chosen(
            among           : screens ?? [builtIn, external, seat],
            pointer         : pointer,
            keyWindowDisplay: key
        )
    }

    private static func screen(
        _ id  : CGDirectDisplayID,
        x     : CGFloat,
        y     : CGFloat,
        width : CGFloat,
        height: CGFloat,
        isSeat: Bool = false
    ) -> PersonScreen.Screen {
        PersonScreen.Screen(
            displayID: id,
            frame    : CGRect(
                x     : x,
                y     : y,
                width : width,
                height: height
            ),
            isSeat   : isSeat
        )
    }
}
