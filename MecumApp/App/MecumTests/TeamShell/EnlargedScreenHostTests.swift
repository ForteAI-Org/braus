//
//  EnlargedScreenHostTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import AppKit
import Testing
@testable import Mecum

/// The overlay in a window that is never shown, so no test touches the desktop
/// or the keyboard of whoever is using the Mac; the window still drops every
/// event the test did not send itself.
@MainActor
@Suite("The enlarged screen's overlay")
struct EnlargedScreenHostTests {

    /// An overlay over a container that also holds a small view, as the conversation holds its card.
    @MainActor
    private final class Rig {

        /// A count the overlay's close request raises.
        final class Requests {

            var count = 0
        }

        let window  = TestInputWindow(
            contentRect: NSRect(
                x     : 0,
                y     : 0,
                width : 900,
                height: 600
            ),
            styleMask  : [.titled, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        let small   : NSView
        let screen  = NSView()
        let requests = Requests()
        let host    : EnlargedScreenHostView

        init(
            reducesMotion: Bool,
            nativeSize   : CGSize = CGSize(
                width : 1600,
                height: 1000
            ),
            smallSize    : CGSize = CGSize(
                width : 160,
                height: 100
            )
        ) {
            small = NSView(frame: NSRect(
                origin: CGPoint(
                    x: 640,
                    y: 400
                ),
                size  : smallSize
            ))
            let container = NSView(frame: NSRect(
                x     : 0,
                y     : 0,
                width : 900,
                height: 600
            ))
            small.wantsLayer = true
            container.addSubview(small)

            let requests = requests
            host = EnlargedScreenHostView(
                screen        : screen,
                nativeSize    : nativeSize,
                opener        : small,
                reducesMotion : reducesMotion,
                label         : "Atlas’s screen",
                onRequestClose: { requests.count += 1 }
            )
            host.frame = container.bounds
            container.addSubview(host)
            window.contentView = container
            host.layoutSubtreeIfNeeded()
        }

        var closeButton: NSButton? { host.subviews.compactMap { $0 as? NSButton }.first }

        func press(
            _ code   : UInt16,
            modifiers: NSEvent.ModifierFlags = []
        ) {
            guard let event = NSEvent.keyEvent(
                with                       : .keyDown,
                location                   : .zero,
                modifierFlags              : modifiers,
                timestamp                  : ProcessInfo.processInfo.systemUptime,
                windowNumber               : window.windowNumber,
                context                    : nil,
                characters                 : "",
                charactersIgnoringModifiers: "",
                isARepeat                  : false,
                keyCode                    : code
            ) else { return }

            window.send(event)
        }

        /// A click as the window would route it: to the deepest view under the point, which hands it up.
        func click(at point: CGPoint) {
            guard let event = NSEvent.mouseEvent(
                with         : .leftMouseDown,
                location     : point,
                modifierFlags: [],
                timestamp    : ProcessInfo.processInfo.systemUptime,
                windowNumber : window.windowNumber,
                context      : nil,
                eventNumber  : TestInputWindow.clickNumber,
                clickCount   : 1,
                pressure     : 1
            ) else { return }

            window.contentView?.hitTest(point)?.mouseDown(with: event)
        }
    }

    @Test("The screen keeps the seat's proportions, centered, inside the margins")
    func theScreenIsFittedAndCentered() {
        let rig = Rig(reducesMotion: false)
        rig.host.needsLayout = true
        rig.host.layoutSubtreeIfNeeded()

        // A window larger than the room is fitted; the title bar reaches in, and the screen keeps clear of it.
        let inset = rig.host.topInset
        #expect(inset > 0)
        let frame = rig.screen.frame
        #expect(abs(frame.width / frame.height - 1.6) < 0.001)
        #expect(frame.minX >= 28 - 0.01 && frame.maxX <= 900 - 28 + 0.01)
        #expect(frame.minY >= 28 - 0.01 && frame.maxY <= 600 - inset - 28 + 0.01)
        #expect(abs(frame.midX - 450) < 0.5)
    }

    @Test("A window smaller than the room shows at its own size, centered, never scaled up")
    func aSmallWindowShowsAtItsOwnSize() {
        let rig = Rig(
            reducesMotion: false,
            nativeSize   : CGSize(
                width : 230,
                height: 408
            ),
            smallSize    : CGSize(
                width : 140,
                height: 248
            )
        )
        let inset = rig.host.topInset
        let frame = rig.screen.frame
        #expect(abs(frame.width - 230) < 0.01 && abs(frame.height - 408) < 0.01)
        #expect(abs(frame.midX - 450) < 0.5)
        #expect(abs(frame.midY - (28 + (600 - inset - 56) / 2)) < 0.5)
    }

    @Test("A window smaller than the card it grows from stays at least the card's size")
    func aSmallWindowIsNeverSmallerThanItsCard() {
        let rig = Rig(
            reducesMotion: false,
            nativeSize   : CGSize(
                width : 230,
                height: 408
            ),
            smallSize    : CGSize(
                width : 268,
                height: 475
            )
        )
        let frame = rig.screen.frame
        #expect(frame.width >= 268 - 0.01 && frame.height >= 475 - 0.5)
        #expect(abs(frame.width / frame.height - 230.0 / 408.0) < 0.001)
        #expect(abs(frame.midX - 450) < 0.5)
    }

    @Test("It grows from the small view with springs on the render server, and with Reduce Motion only fades")
    func itGrowsFromTheSmallView() throws {
        let rig   = Rig(reducesMotion: false)
        let layer = try #require(rig.screen.layer)

        // A layer's position is its anchor point, which AppKit puts at the origin of a view's layer.
        let position = try #require(layer.animation(forKey: "position") as? CASpringAnimation)
        let from     = try #require(position.fromValue as? CGPoint)
        let toValue  = try #require(position.toValue as? CGPoint)
        let small    = rig.small.frame
        #expect(abs(from.x - (small.minX + layer.anchorPoint.x * small.width)) < 0.5)
        #expect(abs(from.y - (small.minY + layer.anchorPoint.y * small.height)) < 0.5)
        #expect(toValue == layer.position)
        #expect(layer.animation(forKey: "size") is CASpringAnimation)
        #expect(rig.host.layer?.animation(forKey: "fade") == nil)

        let calm      = Rig(reducesMotion: true)
        let calmLayer = try #require(calm.screen.layer)
        #expect(calmLayer.animation(forKey: "position") == nil)
        #expect(calmLayer.animation(forKey: "size") == nil)
        #expect(calm.host.layer?.animation(forKey: "fade") is CABasicAnimation)
    }

    @Test("Escape, the close button and a click on the backdrop ask to close; a click on the screen does not")
    func closingRequests() throws {
        let rig = Rig(reducesMotion: false)
        #expect(rig.window.firstResponder === rig.host)

        rig.press(53)
        #expect(rig.requests.count == 1)

        rig.click(at: CGPoint(
            x: 4,
            y: 4
        ))
        #expect(rig.requests.count == 2)

        rig.click(at: CGPoint(
            x: rig.screen.frame.midX,
            y: rig.screen.frame.midY
        ))
        #expect(rig.requests.count == 2)

        let button = try #require(rig.closeButton)
        button.performClick(nil)
        #expect(rig.requests.count == 3)
    }

    @Test("Tab moves the keyboard only between the overlay and its close button")
    func theKeyboardStaysInside() throws {
        let rig    = Rig(reducesMotion: false)
        let button = try #require(rig.closeButton)

        rig.press(48)
        #expect(rig.window.firstResponder === button)
        rig.press(
            48,
            modifiers: .shift
        )
        #expect(rig.window.firstResponder === rig.host)
        rig.press(48)
        rig.press(48)
        #expect(rig.window.firstResponder === rig.host)
    }

    @Test("Closing shrinks into the small view, hands it the last frame, gives the keyboard back and reports it landed")
    func closingLands() async throws {
        let rig     = Rig(reducesMotion: false)
        let layer   = try #require(rig.screen.layer)
        let landing = Landing()
        let picture = NSImage(size: NSSize(
            width : 1,
            height: 1
        ))
        layer.contents = picture

        rig.host.close(into: rig.small) { landing.isLanded = true }
        #expect(layer.animation(forKey: "size") is CASpringAnimation)
        let position = try #require(layer.animation(forKey: "position") as? CASpringAnimation)
        #expect(position.toValue as? CGPoint == layer.position)
        #expect(abs(rig.screen.frame.midX - rig.small.frame.midX) < 0.5)
        #expect(abs(rig.screen.frame.width - rig.small.frame.width) < 0.5)
        try await landing.wait()
        #expect(rig.small.layer?.contents as AnyObject? === picture)
        #expect(rig.window.firstResponder !== rig.host)
    }

    @Test("With Reduce Motion, and with no small view to land in, closing fades and reports it landed")
    func closingFades() async throws {
        let calm        = Rig(reducesMotion: true)
        let calmLanding = Landing()
        calm.host.close(into: calm.small) { calmLanding.isLanded = true }
        #expect(calm.screen.frame.width > calm.small.frame.width)
        try await calmLanding.wait()

        let lost        = Rig(reducesMotion: false)
        let lostLanding = Landing()
        lost.host.close(into: nil) { lostLanding.isLanded = true }
        try await lostLanding.wait()
    }

    /// Whether a close has reported its landing, which a test waits for.
    @MainActor
    private final class Landing {

        var isLanded = false

        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !isLanded, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(isLanded)
        }
    }
}
