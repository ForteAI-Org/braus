//
//  HouseRoomsKeyStopTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import Metal
import SeatBroker
import SwiftUI
import Testing
@testable import Braus

/// The rooms grid as a stop in the Tab order that the arrow keys and Return drive.
@MainActor
@Suite("The rooms grid as a keyboard stop")
struct HouseRoomsKeyStopTests {

    @Test("The stop takes the keyboard and never a click, and the arrows, Return and other keys go where they should")
    func stopView() throws {
        let stop = HouseRoomsKeyStop.StopView()
        var moves  : [MoveCommandDirection] = []
        var returns = 0
        stop.move    = { moves.append($0) }
        stop.confirm = { _ in returns += 1 }

        #expect(stop.acceptsFirstResponder)
        #expect(stop.canBecomeKeyView)
        #expect(stop.isAccessibilityElement())
        #expect(stop.accessibilityLabel() == "Workers")
        #expect(stop.hitTest(NSPoint(
            x: 0,
            y: 0
        )) == nil)

        for (code, direction) in [
            (UInt16(123), MoveCommandDirection.left),
            (124, .right),
            (125, .down),
            (126, .up),
        ] {
            stop.keyDown(with: try Self.key(code))
            #expect(moves.last == direction)
        }
        #expect(moves.count == 4)
        stop.keyDown(with: try Self.key(36))
        stop.keyDown(with: try Self.key(76))
        #expect(returns == 2)
        // A shortcut is not the stop's: Command-Down moves nothing.
        stop.keyDown(with: try Self.key(
            125,
            modifiers: [.command]
        ))
        #expect(moves.count == 4)
    }

    @Test("Hosted in the grid, the stop is a key view and the arrows move the selection")
    func gridKeyStop() async throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }

        let team = TeamModel(
            store      : try WorkspaceStore.opening(in: directory),
            connections: ModelSettingsStore(),
            broker     : SeatBroker()
        )
        let workers = Array(HouseFixture.workers.prefix(4))
        var selection: HouseWorker.ID? = workers[0].id
        let host = NSHostingView(rootView: HouseRoomsGrid(
            workers   : workers,
            columns   : 2,
            roomsWidth: 260,
            selection : Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            team      : team,
            edit      : { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(
                x     : 0,
                y     : 0,
                width : 280,
                height: 600
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.contentView          = host
        defer { window.close() }
        // The stop is handed its closures in SwiftUI's next update.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }

        let stop = try #require(Self.find(HouseRoomsKeyStop.StopView.self, in: host))
        #expect(stop.canBecomeKeyView)
        #expect(window.makeFirstResponder(stop))
        #expect(window.firstResponder === stop)

        stop.keyDown(with: try Self.key(125))
        #expect(selection == workers[1].id)
        stop.keyDown(with: try Self.key(124))
        #expect(selection == workers[2].id)
        // The first room spans the row above the others.
        stop.keyDown(with: try Self.key(126))
        #expect(selection == workers[0].id)
        stop.keyDown(with: try Self.key(126))
        #expect(selection == workers[0].id)

        // A room is not a stop of its own: the grid is the one.
        #expect(Self.find(NSButton.self, in: host).map { !$0.canBecomeKeyView } ?? true)
    }

    private static func key(
        _ code    : UInt16,
        modifiers : NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with                       : .keyDown,
            location                   : .zero,
            modifierFlags              : modifiers,
            timestamp                  : 0,
            windowNumber               : 0,
            context                    : nil,
            characters                 : "",
            charactersIgnoringModifiers: "",
            isARepeat                  : false,
            keyCode                    : code
        ))
    }

    private static func find<View: NSView>(
        _ type : View.Type,
        in view: NSView
    ) -> View? {
        if let found = view as? View { return found }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }
}
