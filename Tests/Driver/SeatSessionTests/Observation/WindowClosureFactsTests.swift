//
//  WindowClosureFactsTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The rule over the facts measured on 12/10/2026 (DaVinci Resolve, Prism Launcher): the
/// Project Manager is a panel, the only window, with no main window; the editor and Prism are
/// standard main windows with a close button.
@Suite("Whether closing a window may end its application")
struct WindowClosureFactsTests {

    private func facts(
        role     : SurfaceRole?,
        windows  : Int?  = 1,
        onScreen : Int?  = 1,
        main     : Bool? = false,
        cancel   : Bool? = false,
        regular  : Bool? = true
    ) -> WindowClosureFacts {
        WindowClosureFacts(
            role                    : role,
            accessibilityWindowCount: windows,
            onScreenWindowCount     : onScreen,
            hasMainWindow           : main,
            hasCancelButton         : cancel,
            isRegularApplication    : regular
        )
    }

    @Test("the Project Manager is at risk: a panel, the only window, no main window, no cancel button")
    func projectManager() {
        #expect(facts(role: .interactivePanel).mayEndTheApplication)
    }

    @Test("a document window is never at risk: the editor, Prism, Calculator and Finder")
    func documentWindows() {
        #expect(!facts(role: .document, main: true).mayEndTheApplication)
        #expect(!facts(role: .document, main: true, cancel: false).mayEndTheApplication)
        #expect(!facts(role: .document, windows: nil, onScreen: nil, main: nil).mayEndTheApplication)
    }

    @Test("a sheet or dialog over a document is not the only window")
    func dialogOverADocument() {
        #expect(!facts(role: .dialog, windows: 2, onScreen: 2, main: true, cancel: true).mayEndTheApplication)
        #expect(!facts(role: .dialog, windows: 1, onScreen: 2, main: true, cancel: true).mayEndTheApplication)
        #expect(!facts(role: .interactivePanel, windows: 2, onScreen: 1).mayEndTheApplication)
    }

    @Test("an accessory or menu bar application is never at risk")
    func accessoryApplication() {
        #expect(!facts(role: .interactivePanel, regular: false).mayEndTheApplication)
        #expect(!facts(role: .interactivePanel, windows: nil, regular: false).mayEndTheApplication)
    }

    @Test("an activation policy that cannot be read fails closed unless the window is a document")
    func unknownActivationPolicy() {
        #expect(facts(role: .interactivePanel, regular: nil).mayEndTheApplication)
        #expect(facts(role: nil, regular: nil).mayEndTheApplication)
        #expect(!facts(role: .document, main: true, regular: nil).mayEndTheApplication)
    }

    @Test("a lone dialog with a main window is at risk only when it can be cancelled")
    func cancellableDialog() {
        #expect(facts(role: .dialog, main: true, cancel: true).mayEndTheApplication)
        #expect(!facts(role: .dialog, main: true, cancel: false).mayEndTheApplication)
        #expect(facts(role: .dialog, main: true, cancel: nil).mayEndTheApplication, "unreadable fails closed")
    }

    @Test("an unreadable count or main window fails closed unless the window is a document")
    func unreadableFailsClosed() {
        #expect(facts(role: .interactivePanel, windows: nil).mayEndTheApplication)
        #expect(facts(role: .interactivePanel, onScreen: nil).mayEndTheApplication)
        #expect(facts(role: .interactivePanel, main: nil).mayEndTheApplication)
        #expect(facts(role: nil, windows: nil).mayEndTheApplication)
        #expect(facts(role: .dialog, windows: nil, onScreen: nil, main: nil).mayEndTheApplication)
    }

    @Test("only visible windows at ordinary levels and a real size are counted, on any display")
    func countedWindows() {
        func surface(
            _ number : Int,
            level    : Int = 0,
            visible  : Bool = true,
            size     : CGSize = CGSize(width: 800, height: 600),
            at origin: CGPoint = .zero
        ) -> WindowSurface {
            WindowSurface(
                reference: WindowReference(
                    processID   : 77,
                    windowNumber: number,
                    frame       : CGRect(origin: origin, size: size)
                ),
                level    : level,
                isVisible: visible
            )
        }
        #expect(WindowClosureFacts.countedWindows(in: nil) == nil)
        #expect(WindowClosureFacts.countedWindows(in: []) == 0)
        #expect(WindowClosureFacts.countedWindows(in: [surface(1)]) == 1)
        // Layer 4 is how a Qt window reads when frontmost; the virtual display is far from the origin.
        let front = surface(1, level: 4, at: CGPoint(x: 9_000, y: 0))
        #expect(WindowClosureFacts.countedWindows(in: [front, surface(2, level: 8)]) == 2)
        #expect(WindowClosureFacts.countedWindows(in: [
            surface(1),
            surface(2, level: 101),
            surface(3, level: 25),
            surface(4, visible: false),
            surface(5, size: CGSize(width: 484, height: 32)),
        ]) == 1)
        // Finder's desktop is a window of the process at a negative level, below every window.
        let desktop = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(WindowClosureFacts.countedWindows(in: [surface(1), surface(2, level: desktop)]) == 1)
        #expect(WindowClosureFacts.countedWindows(in: [surface(1, level: -1)]) == 0)
    }
}
