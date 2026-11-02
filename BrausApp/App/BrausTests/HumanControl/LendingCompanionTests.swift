//
//  LendingCompanionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import Testing
@testable import Braus

@Suite("LendingCompanion")
@MainActor
struct LendingCompanionTests {

    @Test("After a notice with no press, as a zoom animates, the border is read until the window stands still")
    func settlesAfterAZoom() {
        let start = ContinuousClock.now
        var settle = LendingCompanion.NoticeSettle(at: start)
        // A zoom from 800 by 600 to the screen's visible frame, one read per display frame.
        let zoom = [
            CGRect(x: 300, y: 200, width: 800, height: 600),
            CGRect(x: 200, y: 140, width: 1100, height: 760),
            CGRect(x: 80, y: 60, width: 1400, height: 900),
            CGRect(x: 0, y: 25, width: 1512, height: 957),
        ]
        var reads = 0
        for (index, frame) in zoom.enumerated() {
            reads += 1
            let moving = settle.read(frame, at: start + .milliseconds(16 * index))
            #expect(moving, "the window still moves")
        }
        let still = zoom[zoom.count - 1]
        var going = true
        while going {
            going  = settle.read(still, at: start + .milliseconds(16 * reads))
            reads += 1
        }
        #expect(reads == zoom.count + LendingCompanion.NoticeSettle.stillReads, "stops once it stood still")

        var gone      = LendingCompanion.NoticeSettle(at: start)
        let offScreen = gone.read(nil, at: start)
        #expect(!offScreen, "a window off screen ends the reads")
        var long      = LendingCompanion.NoticeSettle(at: start)
        let tooLong   = long.read(zoom[1], at: start + LendingCompanion.NoticeSettle.limit)
        #expect(!tooLong, "and so does the limit")
    }


    @Test(
        "Lent frames convert to AppKit space on the built-in screen and the external one beside it",
        arguments: [
            // A window on the built-in screen, the menu-bar screen at (0, 0, 1512, 982).
            (CGRect(x: 356, y: 191, width: 800, height: 600), CGRect(x: 356, y: 191, width: 800, height: 600)),
            // A window centred on the external screen at (1512, 317, 1920, 1080), above the built-in one's top.
            (CGRect(x: 2072, y: -175, width: 800, height: 600), CGRect(x: 2072, y: 557, width: 800, height: 600)),
            // The external screen's whole frame.
            (CGRect(x: 1512, y: -415, width: 1920, height: 1080), CGRect(x: 1512, y: 317, width: 1920, height: 1080)),
        ]
    )
    func appKitFrame(windowServer: CGRect, appKit: CGRect) {
        let menuBar = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(LendingCompanion.appKitFrame(windowServer, menuBarScreen: menuBar) == appKit)
        // The same flip takes it back.
        #expect(LendingCompanion.appKitFrame(appKit, menuBarScreen: menuBar) == windowServer)
    }

    @Test("The companion shows on lend, asks to finish once on Yes and goes when control ends")
    func lifecycle() {
        // Yes before lending, lend twice, Yes twice, end twice, lend again after the end.
        var life = LendingCompanion.Lifecycle()
        let answered = [
            life.finishRequested(), life.lent(), life.lent(), life.finishRequested(),
            life.finishRequested(), life.ended(), life.ended(), life.lent(),
        ]
        #expect(answered == [false, true, false, true, false, true, false, false])
        #expect(life.phase == .ended)

        // End Control from the bar hides what lending showed, and a later Yes finishes nothing.
        var fromBar = LendingCompanion.Lifecycle()
        let ended = [fromBar.lent(), fromBar.ended(), fromBar.finishRequested()]
        #expect(ended == [true, true, false])

        // Nothing to hide when lending never succeeded, and nothing shows after.
        var neverLent = LendingCompanion.Lifecycle()
        let unlent = [neverLent.ended(), neverLent.lent()]
        #expect(unlent == [false, false])
    }

    @Test("Every end of the episode takes the companion off at once: Yes, End Control, a closed session, quitting, a block")
    func everyEndDismisses() {
        typealias Life = LendingCompanion.Lifecycle
        // Yes: the border goes as the exit begins, control finishes once, and its finishing ends the rest.
        var yes = Life()
        #expect(yes.control(lent: true, ending: false) == .present)
        let exitStarted = yes.exitStarted()
        #expect(exitStarted)
        #expect(yes.control(lent: true, ending: false) == nil)
        let finishRequested = yes.finishRequested()
        #expect(finishRequested)
        #expect(yes.control(lent: true, ending: true) == .dismiss)
        #expect(yes.phase == .ended)

        // End Control, quitting (both finish control) and a block end it while the window is still lent;
        // a closed session clears the window too, and a lent window gone alone ends it as well.
        for (lent, ending) in [(true, true), (false, true), (false, false)] {
            var life = Life()
            _ = life.control(lent: true, ending: false)
            #expect(life.control(lent: lent, ending: ending) == .dismiss, "lent \(lent), ending \(ending)")
            #expect(!life.exitStarted() && !life.finishRequested())
        }

        // Ending before lending showed anything dismisses nothing, and lending after it shows nothing.
        var early = Life()
        #expect(early.control(lent: false, ending: false) == nil)
        #expect(early.control(lent: false, ending: true) == nil)
        #expect(early.control(lent: true, ending: false) == nil)
    }

    @Test("With Stage Manager, the border goes as the lent window shrinks to the strip and stays if it does not")
    func stageWatchLeaving() {
        let marked = CGSize(width: 656, height: 422)
        // Frames read every 33 ms after another app came to the front, as TextEdit left the stage.
        var leaving = LendingCompanion.StageWatch(marked: marked, inFront: false, at: 0)
        #expect(leaving.read(CGRect(x: 570, y: 33, width: 656, height: 422), at: 0.03) == nil)
        #expect(leaving.read(CGRect(x: 546, y: 77, width: 616, height: 408), at: 0.13) == .left)
        #expect(leaving.isOver)

        // Another app on another screen, or sharing the stage: the window holds still and keeps its border.
        var staying = LendingCompanion.StageWatch(marked: marked, inFront: false, at: 0)
        let still = CGRect(x: 570, y: 33, width: 656, height: 422)
        let verdicts = stride(from: 0.0, through: 1.1, by: 0.033).map { staying.read(still, at: $0) }
        #expect(verdicts.compactMap { $0 } == [.back(still)])
        #expect(staying.isOver)

        // Off screen, the notices decide; with the border already hidden, another app changes nothing.
        var gone = LendingCompanion.StageWatch(marked: marked, inFront: false, at: 0)
        #expect(gone.read(nil, at: 0.03) == nil && gone.isOver)
        var hidden = LendingCompanion.StageWatch(marked: nil, inFront: false, at: 0)
        #expect(hidden.read(still, at: 0.03) == nil && hidden.isOver)
    }

    @Test("With Stage Manager, the border comes back once the lent window has grown back nearly still, not in the strip")
    func stageWatchComingBack() {
        // TextEdit's frames as it came back from the strip after its activation.
        let frames = [
            (0.00, CGRect(x: 16, y: 767, width: 100, height: 123)),
            (0.12, CGRect(x: 72, y: 716, width: 128, height: 145)),
            (0.21, CGRect(x: 401, y: 347, width: 390, height: 298)),
            (0.34, CGRect(x: 537, y: 93, width: 602, height: 402)),
            (0.44, CGRect(x: 561, y: 47, width: 644, height: 419)),
            (0.54, CGRect(x: 568, y: 35, width: 655, height: 422)),
            (0.58, CGRect(x: 569, y: 34, width: 656, height: 422)),
            (0.77, CGRect(x: 570, y: 33, width: 656, height: 422)),
            (0.81, CGRect(x: 570, y: 33, width: 656, height: 422)),
            (0.94, CGRect(x: 570, y: 33, width: 656, height: 422)),
        ]
        var watch = LendingCompanion.StageWatch(marked: nil, inFront: true, at: 0)
        let verdicts = frames.map { watch.read($0.1, at: $0.0) }
        // Nothing while it grows; nearly still from 0.58 s, the border follows its last points until it rests.
        #expect(verdicts.prefix(6).allSatisfy { $0 == nil })
        #expect(verdicts[6] == .back(frames[6].1))
        #expect(verdicts.last == .back(frames.last!.1))
        #expect(watch.isOver)

        // Its app in front but the window left in the strip: it never moved, so no border on the thumbnail.
        var stuck = LendingCompanion.StageWatch(marked: nil, inFront: true, at: 0)
        let thumbnail = frames[0].1
        let stuckVerdicts = stride(from: 0.0, through: 1.1, by: 0.033).map { stuck.read(thumbnail, at: $0) }
        #expect(stuckVerdicts.allSatisfy { $0 == nil })
        #expect(stuck.isOver)
    }

    @Test("The border follows the lent app's largest window, not a decoration above it")
    func stackOfTheLentApplication() {
        func row(_ number: Int, pid: pid_t, layer: Int = 0, _ frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary]
        }
        // Front to back, as the window server lists them: Pro Tools' decoration above its Edit window.
        let rows = [
            row(9, pid: 7, layer: 25, CGRect(x: 0, y: 0, width: 400, height: 30)),
            row(31713, pid: 8803, CGRect(x: 137, y: 98, width: 66, height: 20)),
            row(500, pid: 7, CGRect(x: 0, y: 0, width: 900, height: 700)),
            row(18623, pid: 8803, CGRect(x: 125, y: 94, width: 1261, height: 827)),
            row(501, pid: 7, CGRect(x: 0, y: 0, width: 800, height: 600)),
        ]
        #expect(LendingCompanion.largestWindow(of: 8803, rows: rows) == 18623)
        #expect(LendingCompanion.largestWindow(of: 1, rows: rows) == nil)
    }

    @Test("The border stays on the lent window, never on one left on the Seat's display")
    func trackedWindow() {
        func row(_ number: Int, _ frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid_t(817), kCGWindowLayer as String: 0,
             kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary]
        }
        // A Safari window, 18005, stayed on the Seat's display when its move failed, and the person
        // made the lent one, 46324, smaller than it.
        let seat  = CGRect(x: 1920, y: 1200, width: 2560, height: 1440)
        let rows  = [
            row(46324, CGRect(x: -1795, y: -692, width: 998, height: 717)),
            row(18005, CGRect(x: 2143, y: 1228, width: 1298, height: 949)),
            row(46400, CGRect(x: -1500, y: -600, width: 1100, height: 800)),
        ]
        #expect(LendingCompanion.trackedWindow(of: 817, anchor: 46324, rows: rows, seats: [seat]) == 46324)
        // The lent window off screen: the largest on the person's screen, never the Seat's.
        #expect(LendingCompanion.trackedWindow(of: 817, anchor: 46324, rows: Array(rows.dropFirst()), seats: [seat])
            == 46400)
        #expect(LendingCompanion.trackedWindow(of: 817, anchor: 46324, rows: [rows[1]], seats: [seat]) == nil)
        #expect(LendingCompanion.largestWindow(of: 817, rows: rows) == 18005)
    }

    @Test("The border follows the lent window the person focused, never one on the Seat, else the anchor")
    func trackedFocusedWindow() {
        func row(_ number: Int, _ frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid_t(817), kCGWindowLayer as String: 0,
             kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary]
        }
        let seat    = CGRect(x: 1920, y: 1200, width: 2560, height: 1440)
        let anchor  = CGRect(x: -1727, y: -676, width: 1298, height: 949)
        let other   = CGRect(x: -1298, y: -267, width: 1298, height: 900)
        let stayed  = CGRect(x: 2143, y: 1228, width: 1298, height: 949)
        let decor   = CGRect(x: -1711, y: -660, width: 66, height: 20)
        let rows    = [row(46693, decor), row(18005, other), row(46674, anchor), row(46400, stayed)]
        let lent: Set<Int> = [46674, 18005, 46693, 46400]
        func tracked(_ focused: CGRect?) -> Int? {
            LendingCompanion.trackedWindow(of: 817, anchor: 46674, focused: focused, lent: lent, rows: rows,
                                           seats: [seat])
        }
        #expect(tracked(other) == 18005, "the window the person works in")
        #expect(tracked(other.offsetBy(dx: 0.5, dy: -0.5)) == 18005, "Accessibility and the window server agree within a point")
        #expect(tracked(anchor) == 46674)
        #expect(tracked(stayed) == 46674, "a window left on the Seat's display is never followed")
        #expect(tracked(nil) == 46674, "no focused window: the anchor")
        #expect(tracked(CGRect(x: 0, y: 0, width: 500, height: 400)) == 46674, "a focused window not lent: the anchor")
        #expect(LendingCompanion.trackedWindow(of: 817, anchor: 46674, focused: other, lent: [46674], rows: rows,
                                               seats: [seat]) == 46674, "only among the lent windows")
    }

    @Test("The border marks a window only while it is on screen: not minimised, closed or its app hidden")
    func onScreenFrame() {
        let frame = CGRect(x: 125, y: 94, width: 1261, height: 827)
        func row(onScreen: Bool?) -> [String: Any] {
            var row: [String: Any] = [kCGWindowNumber as String: 18623,
                                      kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary]
            if let onScreen { row[kCGWindowIsOnscreen as String] = onScreen }
            return row
        }
        #expect(LendingCompanion.onScreenFrame(in: [row(onScreen: true)]) == frame)
        // Minimised, the window server keeps its row without the on-screen flag.
        #expect(LendingCompanion.onScreenFrame(in: [row(onScreen: nil)]) == nil)
        #expect(LendingCompanion.onScreenFrame(in: [row(onScreen: false)]) == nil)
        // Closed, or its app hidden, there is no row at all.
        #expect(LendingCompanion.onScreenFrame(in: []) == nil)
    }

    @Test("A press on the window or just past its resize edges follows it, one farther out does not")
    func pressGrabs() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let grabs  = [
            CGPoint(x: 500, y: 690), CGPoint(x: 95, y: 400), CGPoint(x: 906, y: 706), CGPoint(x: 300, y: 920),
            CGPoint(x: 80, y: 400),
        ].map { LendingCompanion.pressGrabs($0, window: window) }
        #expect(grabs == [true, true, true, false, false])
    }

    @Test("Only a read where the pointer put the window, give or take the pointer's way meanwhile, is a drag")
    func movesWithPointer() {
        let pressed = CGRect(x: 100, y: 100, width: 800, height: 600)
        let grab    = CGPoint(x: 400, y: 680)
        func moves(_ read: CGRect, issued: CGPoint, pointer: CGPoint) -> Bool {
            LendingCompanion.movesWithPointer(read, pressed: pressed, grab: grab, issued: issued, pointer: pointer)
        }
        let answers = [
            // Dragged by its title bar: read where the pointer, gone 5 points on since, put it.
            moves(CGRect(x: 197, y: 72, width: 800, height: 600), issued: CGPoint(x: 495, y: 652),
                  pointer: CGPoint(x: 500, y: 650)),
            // A press on its content: the window stays where it was.
            moves(pressed, issued: CGPoint(x: 495, y: 652), pointer: CGPoint(x: 500, y: 650)),
            // A resize from its corner.
            moves(CGRect(x: 100, y: 70, width: 900, height: 630), issued: CGPoint(x: 995, y: 72),
                  pointer: CGPoint(x: 1000, y: 70)),
            // Held under the menu bar while the pointer goes on up.
            moves(CGRect(x: 100, y: 300, width: 800, height: 600), issued: CGPoint(x: 400, y: 975),
                  pointer: CGPoint(x: 400, y: 980)),
            // Moved by the app itself, 40 points behind the pointer.
            moves(CGRect(x: 160, y: 100, width: 800, height: 600), issued: CGPoint(x: 498, y: 680),
                  pointer: CGPoint(x: 500, y: 680)),
        ]
        #expect(answers == [true, false, false, false, false])
    }
}
