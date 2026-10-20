//
//  SeatRungMappingTests.swift
//  Braus
//

import EngineCore
import Foundation
import SeatCore
import SeatDriving
import Testing
@testable import SeatBroker

/// The Seat's send as the desktop session records it (M05): the receipt's posting call is the rung, the counts are
/// `how`, nothing is skipped; a receipt of no event is a send like any other. This is the mapping alone: what hands it
/// to the recorder is `BrokeredAutomationSession.handRung`, read by its source, and the actuator's take is
/// `BorrowedSeatTargetTests`.
@Suite("The Seat's rung as the record keeps it")
struct SeatRungMappingTests {

    private static func receipt(_ poster: PostRoute, events: Int) -> InputReceipt {
        InputReceipt(eventCount: events, route: InputRoute(poster: poster, routedEventCount: events, windowNumber: 111_000,
                                                            ownerConnectionID: 7))
    }

    typealias Case = (poster: PostRoute, events: Int, rung: CallRung.Rung, how: String)

    static let cases: [Case] = [
        (.publicProcess, 2, .seatPublicProcess, "2 events, 2 routed to window 111000"),
        (.skyLightProcess, 1, .seatSkyLightProcess, "1 events, 1 routed to window 111000"),
        (.accessibilityAction, 0, .seatAccessibilityAction, "0 events, 0 routed to window 111000"),
    ]

    @Test("each posting call is its own rung, with the counts and nothing skipped", arguments: cases)
    func eachPosterIsARung(_ c: Case) {
        let send = SeatSend(Self.receipt(c.poster, events: c.events))
        #expect(send.poster == c.poster && send.eventCount == c.events && send.routedEventCount == c.events
                && send.windowNumber == 111_000)
        #expect(CallRung(send) == CallRung(rung: c.rung, how: c.how), "\(CallRung(send))")
        #expect(CallRung(send).skipped.isEmpty)
    }
}
