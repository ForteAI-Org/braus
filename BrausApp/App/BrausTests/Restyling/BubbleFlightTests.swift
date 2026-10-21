//
//  BubbleFlightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
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

    @Test("Under Reduce Motion a landing only fades: the box is at the bubble before it shows")
    func reduceMotionLandingOnlyFades() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = true
        let flight = BubbleFlight()
        let id     = UUID()
        // An offscreen window, never shown, gives the layers a context, so animations stay to read.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask  : .borderless,
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = flight.overlay.stage
        flight.launch(
            id,
            text  : "Make the stems too.",
            quote : nil,
            from  : .field(
                CGRect(x: 220, y: 613, width: 308, height: 17),
                scroll: nil
            ),
            column: 560
        )
        // The landing comes a turn after the launch, once its layers are committed and can animate;
        // its animations are read before their transaction commits, as no display plays them here.
        CATransaction.flush()
        flight.land(
            id,
            in: CGRect(x: 560, y: 535, width: 160, height: 39)
        ) {}
        let stage = try #require(flight.overlay.stage.layer?.sublayers)
        #expect(!stage.isEmpty)
        for layer in stage.flatMap(Self.tree) {
            #expect((layer.animationKeys() ?? []).allSatisfy { $0 == "opacity" }, "\(layer.animationKeys() ?? [])")
        }
        let box = try #require(stage.first)
        #expect(box.animationKeys() == ["opacity"], "\(box.animationKeys() ?? [])")
        #expect(box.position == CGPoint(x: 560, y: 535))
    }

    /// `layer` and every layer under it, its mask included.
    private static func tree(_ layer: CALayer) -> [CALayer] {
        [layer]
            + (layer.mask.map(tree) ?? [])
            + (layer.sublayers ?? []).flatMap(tree)
    }

    /// The kinds of `path`'s elements, in order.
    private static func elements(of path: CGPath) -> [CGPathElementType] {
        var kinds: [CGPathElementType] = []
        path.applyWithBlock { kinds.append($0.pointee.type) }
        return kinds
    }
}
