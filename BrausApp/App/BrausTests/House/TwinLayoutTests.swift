//
//  TwinLayoutTests.swift
//  BrausTests
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import Testing
@testable import Braus

@Suite("TwinLayout")
struct TwinLayoutTests {

    private func window(
        _ number: Int,
        _ kind  : TwinWindow.Kind,
        _ frame : CGRect,
        order   : Int,
        level   : Int = 0
    ) -> TwinWindow {
        TwinWindow(
            windowNumber      : number,
            processID         : 1,
            frame             : frame,
            level             : level,
            kind              : kind,
            parentWindowNumber: nil,
            title             : "\(number)",
            order             : order
        )
    }

    @Test("The main window is the one called main, or else the largest at the normal level")
    func mainWindow() {
        let large   = window(1, .other, CGRect(x: 0, y: 0, width: 800, height: 600), order: 1)
        let small   = window(2, .dialog, CGRect(x: 0, y: 0, width: 300, height: 200), order: 0)
        let floated = window(3, .panel, CGRect(x: 0, y: 0, width: 900, height: 900), order: 2, level: 3)
        #expect(TwinLayout.main(of: [small, large, floated])?.windowNumber == 1)
        let named   = window(4, .main, CGRect(x: 0, y: 0, width: 100, height: 100), order: 3)
        #expect(TwinLayout.main(of: [large, named])?.windowNumber == 4)
        // The one chosen before stays while the application has it, larger or listed first or not.
        #expect(TwinLayout.main(of: [named, large], keeping: 1)?.windowNumber == 1)
        #expect(TwinLayout.main(of: [named, large], keeping: 9)?.windowNumber == 4)
    }

    @Test("The person's presses order the screen window and its twins; the application's own reorder wins")
    func stackOrder() {
        let screen = TwinLayout.screenMember
        // Back to front: the application had 2 behind its main window and 3 in front.
        let app = [2, screen, 3]
        #expect(TwinLayout.stack(current: [], app: app, lastApp: [], pinned: []) == app)

        // The person brought the screen window to the front: a window appearing keeps that, in front of it.
        let pressed = [2, 3, screen]
        #expect(TwinLayout.stack(current: pressed, app: [2, screen, 3, 4], lastApp: app, pinned: [])
            == [2, 3, screen, 4])
        // A window closing keeps it too.
        #expect(TwinLayout.stack(current: pressed, app: [screen, 3], lastApp: app, pinned: []) == [3, screen])

        // The application itself brought 2 to the front: its order is taken.
        #expect(TwinLayout.stack(current: pressed, app: [screen, 3, 2], lastApp: app, pinned: [])
            == [screen, 3, 2])

        // A dialog stays above the screen window, whatever was pressed.
        #expect(TwinLayout.stack(current: pressed, app: app, lastApp: app, pinned: [3]) == [2, screen, 3])
        #expect(TwinLayout.settled([5, 2, screen, 3], pinned: [5]) == [2, screen, 5, 3])
        #expect(TwinLayout.settled([2, screen, 5], pinned: [5]) == [2, screen, 5])

        let dialog  = window(5, .dialog, .zero, order: 0)
        let palette = window(6, .other, .zero, order: 0, level: 3)
        let other   = window(7, .other, .zero, order: 0)
        #expect(TwinLayout.staysAbove(dialog) && TwinLayout.staysAbove(palette) && !TwinLayout.staysAbove(other))
    }

    @Test("Every window but the main one and its sheets has a twin, back to front, the largest live")
    func secondaries() {
        let main    = window(1, .main, CGRect(x: 0, y: 0, width: 800, height: 600), order: 3)
        let windows = [
            main,
            window(2, .dialog, CGRect(x: 0, y: 0, width: 300, height: 200), order: 0),
            window(3, .sheet, CGRect(x: 0, y: 0, width: 400, height: 300), order: 1),
            window(4, .panel, CGRect(x: 0, y: 0, width: 200, height: 500), order: 2),
        ]
        let twins = TwinLayout.secondaries(
            of  : windows,
            main: main
        )
        #expect(twins.map(\.windowNumber) == [4, 2], "the sheet shows in the main window's picture")

        let many  = (10..<30).map {
            window($0, .panel, CGRect(x: 0, y: 0, width: CGFloat($0) * 10, height: 100), order: $0)
        }
        #expect(TwinLayout.live(many) == Set((31 - TwinLayout.liveLimit)..<30), "the largest beside the main window's")
    }

    @Test("A twin stands where its window stands around the main one, at the main twin's scale, kept on screen")
    func picture() {
        let main    = window(1, .main, CGRect(x: 100, y: 100, width: 800, height: 600), order: 1)
        let palette = window(2, .panel, CGRect(x: 920, y: 140, width: 200, height: 400), order: 0)
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let real    = TwinLayout.picture(
            of         : palette,
            main       : main,
            mainPicture: CGRect(x: 300, y: 300, width: 800, height: 600),
            visible    : visible
        )
        #expect(real == CGRect(x: 1120, y: 460, width: 200, height: 400), "20 pt right of it, 40 pt below its top")

        let half    = TwinLayout.picture(
            of         : palette,
            main       : main,
            mainPicture: CGRect(x: 300, y: 300, width: 400, height: 300),
            visible    : visible
        )
        #expect(half == CGRect(x: 710, y: 380, width: 100, height: 200), "at the main twin's half scale")

        let kept    = TwinLayout.picture(
            of         : palette,
            main       : main,
            mainPicture: CGRect(x: 1500, y: 300, width: 800, height: 600),
            visible    : visible
        )
        #expect(kept.maxX == visible.maxX, "moved in the least needed to stay on screen")
    }

    @Test("Twins on the display the screen window left come with it, as far as its picture went, kept on the new one")
    func carriedToAnotherDisplay() {
        // The screen window went from the built-in Retina display to an external LG on its
        // left, and the twin it left behind took the still of Take Control there.
        let before = CGRect(x: 316, y: -229, width: 1298, height: 949)
        let after  = CGRect(x: -1727, y: 709, width: 1298, height: 949)
        let lg     = CGRect(x: -2560, y: 0, width: 2560, height: 1415)
        let twin   = CGRect(x: 214, y: 0, width: 400, height: 300)
        #expect(TwinLayout.carried(twin, from: before, to: after, within: lg)
            == CGRect(x: -1829, y: 938, width: 400, height: 300), "the group keeps its layout")
        let beside = CGRect(x: 2200, y: 0, width: 400, height: 300)
        #expect(TwinLayout.carried(beside, from: before, to: after, within: lg).maxX == lg.maxX,
                "moved in the least needed to stay on the display it reached")
    }
}
