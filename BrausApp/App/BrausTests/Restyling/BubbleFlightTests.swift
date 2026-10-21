//
//  BubbleFlightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CoreGraphics
import SwiftUI
import Testing
@testable import Braus

@Suite("BubbleFlight", .serialized)
@MainActor
struct BubbleFlightTests {

    @Test("A flight and the transcript making room settle in the send flight's time")
    func settlesInTheSendFlight() {
        #expect(abs(BubbleFlight.flightDuration - RestylingTiming.sendFlight) < 0.01)
    }

    @Test("The field's corners and the bubble's have the same path elements, so they morph")
    func cornersMorph() {
        let sizes = [
            CGSize(width: 99.5, height: 39),
            CGSize(width: 340.5, height: 39),
            CGSize(width: 434, height: 59),
            CGSize(width: 434, height: 119),
        ]
        for start in sizes {
            for end in sizes {
                let field  = BubbleFlight.Flight.path(
                    in    : CGRect(origin: .zero, size: start),
                    radius: BubbleFlight.fieldRadius
                )
                let bubble = ChatTranscriptView.bubbleShape(tailing: .trailing)
                    .path(in: CGRect(origin: .zero, size: end))
                    .cgPath
                #expect(Self.elements(of: field) == Self.elements(of: bubble))
            }
        }
    }

    @Test("Under Reduce Motion the transcript makes room without moving")
    func reduceMotionMakesRoomAtOnce() {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        #expect(BubbleFlight.transcriptAnimation == nil)
        RestylingMotion.overrideReducesMotion = false
        #expect(BubbleFlight.transcriptAnimation != nil)
    }

    /// The kinds of `path`'s elements, in order.
    private static func elements(of path: CGPath) -> [CGPathElementType] {
        var kinds: [CGPathElementType] = []
        path.applyWithBlock { kinds.append($0.pointee.type) }
        return kinds
    }
}
