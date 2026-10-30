//
//  HumanControlOverlayTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import QuartzCore
import Testing
@testable import Braus

@Suite("HumanControlOverlay", .serialized)
@MainActor
struct HumanControlOverlayTests {

    typealias Layout = HumanControlLayout

    @Test(
        "The panel sits flush in the top-right corner of any visible frame, the worker inside its margins",
        arguments: [
            // The main screen below a 24 pt menu bar, with the Dock at the bottom.
            CGRect(x: 0, y: 70, width: 1512, height: 888),
            // A second screen left of the main one, and one above it with the Dock on its right side.
            CGRect(x: -1920, y: -120, width: 1920, height: 1055),
            CGRect(x: 200, y: 982, width: 2490, height: 1415),
        ]
    )
    func cornerPlacement(visible: CGRect) {
        let panel = Layout.panelFrame(in: visible)
        #expect(panel.maxX == visible.maxX)
        #expect(panel.maxY == visible.maxY)
        #expect(visible.contains(panel))

        let mascot = Layout.mascotCell.offsetBy(dx: panel.minX, dy: panel.minY)
        #expect(abs(visible.maxX - mascot.maxX - Layout.margin) < 1e-9)
        #expect(abs(visible.maxY - mascot.maxY - Layout.headroom) < 1e-9)
        #expect(Layout.headroom >= Layout.jump, "the jumps stay below the menu bar")
    }

    @Test("Every shape stands in the worker's box, and the hole and the contact shadow fit the panel under it")
    func boxHoldsEveryShape() {
        for shape in WorkerShape.allCases {
            let size = Layout.figureSize(of: shape)
            #expect(size.width <= Layout.figure.width && size.height <= Layout.figure.height, "\(shape)")
            #expect(size.width > Layout.sphere * 0.8, "\(shape) is drawn at the larger size")
        }
        #expect(Layout.ground.y - Layout.hole.height / 2 >= 0)
        #expect(Layout.ground.y - Layout.contactShadow.height / 2 >= 0)
        #expect(Layout.contactShadow.width <= Layout.hole.width, "the shadow sinks into the hole")
        #expect(Layout.mascotCell.contains(Layout.mascotCentre))
    }

    @Test("The balloon floats left of the worker, level with its face, inside the panel", arguments: [false, true])
    func balloonBesideTheWorker(countdown: Bool) {
        let height = countdown ? Layout.countdownHeight : Layout.questionHeight
        let balloon = Layout.balloonFrame(height: height)
        let panel   = CGRect(origin: .zero, size: Layout.panelSize)
        #expect(balloon.height == height)
        #expect(panel.contains(balloon))
        #expect(balloon.maxX + Layout.trailRoom == Layout.mascotCell.minX)
        #expect(abs(balloon.midY - Layout.mascotCentre.y) <= 8)
        #expect(balloon.origin == CGPoint(x: balloon.minX.rounded(), y: balloon.minY.rounded()), "whole points")
    }

    @Test("The balloon is medium: wider than the worker, smaller than before, at most two lines tall")
    func balloonSize() {
        #expect(Layout.balloonWidth > Layout.figure.width)
        #expect(Layout.balloonWidth < 210 && Layout.countdownHeight < 72)
        #expect(Layout.questionHeight < Layout.countdownHeight)
    }

    @Test(
        "Opening on its spring, the balloon with its shadow, its trail and the sliding buttons stay inside the panel",
        arguments: [false, true]
    )
    func openingStaysInside(countdown: Bool) {
        let height  = countdown ? Layout.countdownHeight : Layout.questionHeight
        let balloon = Layout.balloonFrame(height: height)
        let panel   = CGRect(origin: .zero, size: Layout.panelSize)
        let peak    = Layout.balloon(balloon, scaledBy: CGFloat(BalloonSpring.opening.peak))
        let shadow  = peak.insetBy(dx: -Layout.shadowReach, dy: -Layout.shadowReach)
        #expect(panel.contains(shadow), "\(shadow) in \(panel)")
        for bubble in Layout.trail(from: balloon) {
            #expect(panel.contains(CGRect(
                x     : bubble.centre.x - bubble.radius,
                y     : bubble.centre.y - bubble.radius,
                width : 2 * bubble.radius,
                height: 2 * bubble.radius
            )))
        }
        let buttons = Layout.buttonFrames(under: balloon)
        for button in [buttons.no, buttons.yes] {
            #expect(panel.contains(button.offsetBy(dx: 0, dy: -Layout.buttonSlide)))
        }

        // Scaling about the anchor keeps the anchor where it is.
        let anchor = CGPoint(
            x: balloon.minX + Layout.balloonAnchor.x * balloon.width,
            y: balloon.minY + Layout.balloonAnchor.y * balloon.height
        )
        let small  = Layout.balloon(balloon, scaledBy: 0.5)
        #expect(abs(small.minX + Layout.balloonAnchor.x * small.width - anchor.x) < 1e-9)
        #expect(abs(small.minY + Layout.balloonAnchor.y * small.height - anchor.y) < 1e-9)
    }

    @Test("The balloon's spring is gentle: it passes its size by a hair at most")
    func gentleSpring() {
        let spring = BalloonSpring.opening
        #expect(spring.dampingRatio < 1)
        #expect(spring.peak > 1 && spring.peak < 1.02)
        let firm = BalloonSpring(stiffness: 320, damping: 12, from: 0.3)
        #expect(firm.peak > 1.2, "the old spring overshot by about a fifth")
        #expect(BalloonSpring(stiffness: 100, damping: 40, from: 0.5).peak == 1, "overdamped never passes")
    }

    @Test(
        "The trail's bubbles shrink from the balloon toward the worker, apart and clear of both",
        arguments: [false, true]
    )
    func trailGeometry(countdown: Bool) throws {
        let height = countdown ? Layout.countdownHeight : Layout.questionHeight
        let balloon = Layout.balloonFrame(height: height)
        let trail   = Layout.trail(from: balloon)
        #expect(trail.count == 3)
        let first = try #require(trail.first)
        let last  = try #require(trail.last)
        #expect(first.centre.x - first.radius > balloon.maxX, "the first bubble is off the balloon")
        #expect(last.centre.x + last.radius < Layout.mascotCell.minX, "the last stops short of the worker")
        for (bubble, next) in zip(trail, trail.dropFirst()) {
            #expect(next.radius < bubble.radius)
            #expect(next.centre.x > bubble.centre.x)
            #expect(abs(next.centre.y - Layout.mascotCentre.y) <= abs(bubble.centre.y - Layout.mascotCentre.y))
            let gap = hypot(next.centre.x - bubble.centre.x, next.centre.y - bubble.centre.y)
            #expect(gap > next.radius + bubble.radius, "bubbles do not touch")
        }
    }

    @Test("Yes and No sit side by side under the balloon, Yes on the right and wider", arguments: [false, true])
    func buttonsUnderTheBalloon(countdown: Bool) {
        let height = countdown ? Layout.countdownHeight : Layout.questionHeight
        let balloon = Layout.balloonFrame(height: height)
        let buttons = Layout.buttonFrames(under: balloon)
        let panel   = CGRect(origin: .zero, size: Layout.panelSize)
        for button in [buttons.no, buttons.yes] {
            #expect(button.maxY == balloon.minY - Layout.buttonGap)
            #expect(panel.contains(button))
            #expect(button.height == Layout.buttonHeight)
        }
        #expect(!buttons.no.intersects(buttons.yes))
        #expect(buttons.yes.minX - buttons.no.maxX == Layout.buttonSpace)
        #expect(buttons.yes.width > buttons.no.width)
        #expect(abs(buttons.no.minX - balloon.minX - (balloon.maxX - buttons.yes.maxX)) < 1e-9, "centred")
        #expect(!buttons.yes.intersects(Layout.mascotCell))
        for origin in [buttons.no.origin, buttons.yes.origin] {
            #expect(origin == CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), "whole points")
        }
    }

    @Test("The pointer near the face makes the worker look toward it; far away it does not")
    func pointerLook() {
        defer { HouseMotion.overrideReducesMotion = nil }
        HouseMotion.overrideReducesMotion = false
        let origin = CGPoint(x: 1000, y: 700)
        let face   = CGPoint(x: origin.x + Layout.mascotCentre.x, y: origin.y + Layout.mascotCentre.y)
        #expect(Layout.isNear(face, panelOrigin: origin))
        #expect(Layout.isNear(CGPoint(x: face.x - Layout.lookRadius, y: face.y), panelOrigin: origin))
        #expect(!Layout.isNear(CGPoint(x: face.x - Layout.lookRadius - 1, y: face.y), panelOrigin: origin))

        // The angle the companion's face gets: left and above is a negative yaw and pitch.
        let host = MascotFace.HostView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        host.sphereSize = 76
        let gaze = WorkerGaze()
        gaze.host = host
        let centre = CGPoint(
            x: host.mascot.frame.minX + host.mascot.faceCenter.x,
            y: host.mascot.frame.minY + host.mascot.faceCenter.y
        )
        gaze.pointerMoved(toWindow: CGPoint(x: centre.x - 60, y: centre.y + 40))
        #expect(host.mascot.yaw < 0)
        #expect(host.mascot.pitch < 0)
        gaze.pointerMoved(toWindow: CGPoint(x: centre.x + 60, y: centre.y - 40))
        #expect(host.mascot.yaw > 0)
        #expect(host.mascot.pitch > 0)
    }

    @Test("The border's panel holds the window, the gap, the line and the halo; the line lies outside the window")
    func borderAroundTheWindow() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 500)
        let border = Layout.borderFrame(around: window)
        let reach  = Layout.borderGap + Layout.borderLine + Layout.borderHalo
        #expect(border == CGRect(x: 100 - reach, y: 200 - reach, width: 800 + 2 * reach, height: 500 + 2 * reach))

        // In the panel: the window's rect, and the line's inner edge a gap outside it.
        let bounds = CGRect(origin: .zero, size: border.size)
        let inner  = bounds.insetBy(dx: Layout.borderWindowInset, dy: Layout.borderWindowInset)
        #expect(inner.size == window.size)
        let lineInnerEdge = Layout.borderLineInset + Layout.borderLine / 2
        #expect(Layout.borderWindowInset - lineInnerEdge == Layout.borderGap)
    }

    @Test("The countdown times out once its seconds have passed")
    func countdownTimesOut() {
        var countdown = TakeBackCountdown(seconds: 3)
        #expect(countdown.label == "Taking it back in 3 s")
        countdown.tick()
        countdown.tick()
        #expect(countdown.answer == nil)
        #expect(countdown.label == "Taking it back in 1 s")
        countdown.tick()
        #expect(countdown.answer == .timeout)
        countdown.tick()
        #expect(countdown.remaining == 0)
        countdown.reply(yes: true)
        #expect(countdown.answer == .timeout, "an answer after the timeout changes nothing")
    }

    @Test("The first answer stands, and stops the count", arguments: [true, false])
    func countdownAnswer(yes: Bool) {
        var countdown = TakeBackCountdown(seconds: 10)
        countdown.tick()
        countdown.reply(yes: yes)
        #expect(countdown.answer == (yes ? .yes : .no))
        countdown.reply(yes: !yes)
        for _ in 0..<20 { countdown.tick() }
        #expect(countdown.answer == (yes ? .yes : .no))
        #expect(countdown.remaining == 9)
    }

    @Test("A countdown of no time has already timed out")
    func emptyCountdown() {
        #expect(TakeBackCountdown(seconds: 0).answer == .timeout)
        #expect(TakeBackCountdown(seconds: -4).answer == .timeout)
    }

    @Test("Reduce Motion turns the jumps through the hole into short fades")
    func reduceMotionExit() {
        #expect(HumanControlExit(reducesMotion: false) == .fall)
        #expect(HumanControlExit(reducesMotion: true) == .fade)
        #expect(HumanControlEntrance(reducesMotion: false) == .rise)
        #expect(HumanControlEntrance(reducesMotion: true) == .fade)
        #expect((0.8...1.2).contains(HumanControlExit.fall.duration))
        #expect((0.8...1.2).contains(HumanControlEntrance.rise.duration))
        #expect(HumanControlExit.fade.duration < HumanControlExit.fall.duration)
        #expect(HumanControlEntrance.fade.duration < HumanControlEntrance.rise.duration)
    }

    @Test("The entrance is the exit played backwards: out of the hole, landing, at rest")
    func entranceMirrorsExit() throws {
        let exit     = HumanControlBeats.exit
        let entrance = HumanControlBeats.entrance
        #expect(entrance == exit.reversed)
        let twice = entrance.reversed
        #expect(zip(twice.times, exit.times).allSatisfy { abs($0 - $1) < 1e-12 }, "twice back is the exit")
        #expect(twice.curves == exit.curves && twice.rise == exit.rise && twice.scaleY == exit.scaleY)
        for beats in [exit, entrance] {
            #expect(beats.times.first == 0 && beats.times.last == 1)
            #expect(zip(beats.times, beats.times.dropFirst()).allSatisfy { $0 < $1 })
            #expect(beats.curves.count == beats.times.count - 1)
            for track in [beats.scaleX, beats.scaleY, beats.rise, beats.shadowScale, beats.shadowOpacity] {
                #expect(track.count == beats.times.count)
            }
        }
        // It starts hidden below the ground, stretched and without a shadow, and ends standing.
        #expect(try #require(entrance.rise.first) < -1)
        #expect(entrance.shadowOpacity.first == 0)
        #expect(entrance.rise.last == 0 && entrance.scaleX.last == 1 && entrance.scaleY.last == 1)
        #expect(entrance.shadowScale.last == 1 && entrance.shadowOpacity.last == 1)
        // The fall eases in; played backwards, the rise out of the hole eases out.
        #expect(exit.curves[4] == .easeIn && entrance.curves[1] == .easeOut)
    }

    @Test("The backdrop's few pixels give one light, stronger the brighter they are, that ignores tiny changes")
    func backdropLight() throws {
        let gray = try #require(BackdropLight.average(of: [10, 20, 30, 255, 30, 40, 50, 255]))
        #expect(abs(gray.x - 20.0 / 255) < 1e-6 && abs(gray.z - 40.0 / 255) < 1e-6)
        #expect(BackdropLight.average(of: [1, 2]) == nil)

        let black = BackdropLight.light(for: .zero)
        let white = BackdropLight.light(for: .one)
        #expect(abs(black.w - 0.2) < 1e-6)
        #expect(abs(white.w - 0.8) < 1e-6)
        #expect(white.x >= white.z, "toward warm white")

        let blue  = BackdropLight.light(for: SIMD3(0.1, 0.2, 0.8))
        #expect(blue.z > blue.x, "the backdrop's hue shows")
        let nudge = BackdropLight.light(for: SIMD3(0.105, 0.2, 0.8))
        #expect(!BackdropLight.differs(nudge, from: blue))
        #expect(BackdropLight.differs(white, from: blue))
    }

    @Test("The border fades off the screen, and shown again while it fades it stays")
    func borderFades() async throws {
        let border = ControlWindowBorder()
        let frame  = CGRect(x: 200, y: 200, width: 400, height: 300)
        border.show(frame: frame)
        border.hide(fade: 0.05)
        #expect(border.isShown, "on screen while it fades")
        border.show(frame: frame)
        try await Task.sleep(for: .milliseconds(400))
        #expect(border.isShown, "the first fade's end leaves the shown border on")

        border.hide(fade: 0.05)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!border.isShown)
        border.hide()
    }
}
