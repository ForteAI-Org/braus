//
//  AppleExtensionPressTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/10/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
@testable import SeatSession
import Testing

/// A press inside an Apple extension's content (a System Settings pane) goes to the same control in
/// the host's own tree when it is there, and every answer to it is logged. The tree is System
/// Settings' Appearance pane as the 15/10/2026 accessibility dump shows it: a group holding
/// buttons, the host's hosting view above them.
@MainActor
@Suite("Apple extension presses go through the host's tree")
struct AppleExtensionPressTests {

    typealias Element = RemoteContentActuationTests.Element

    final class Notes { var lines: [String] = [] }

    struct Pane {
        let endpoint : ResolvedInputEndpoint
        let hostWindow: Element
        let remote   : Element
        let host     : Element
        let notes    : Notes
        let actuator : RemoteContentActuator<Element>
    }

    static let frame = CGRect(x: 2050, y: 480, width: 100, height: 40)

    /// The hit test answers the extension's "Light" button. The host's tree holds a "Light" button
    /// too, under its hosting view, unless `hostHasIt` is false.
    static func pane(hostHasIt: Bool = true, hostFrame: CGRect = Self.frame) throws -> Pane {
        let surface  = FakeGeometry.identity(windowNumber: 878)
        let endpoint = try RemoteContentActuationTests.remoteEndpoint(surface: surface)
        let window   = Element("AXWindow", window: .window(878), processID: surface.processID)
        let content  = Element(kAXGroupRole, window: .window(879), processID: 7_001, parent: window)
        let remote   = Element(kAXButtonRole, window: .window(879), processID: 7_001, parent: content,
                               actions: [kAXPressAction])
        let hosting  = Element("AXHostingView", window: .windowless, processID: surface.processID, parent: window)
        let local    = Element(kAXButtonRole, window: .windowless, processID: surface.processID, parent: hosting,
                               actions: hostHasIt ? [kAXPressAction] : [])
        let wide     = CGRect(x: 2000, y: 400, width: 400, height: 300)
        for element in [window, content, hosting] { element.frame = wide }
        for (element, box) in [(remote, Self.frame), (local, hostFrame)] {
            element.frame = box
            element.title = "Light"
        }
        let notes = Notes()
        return Pane(
            endpoint: endpoint, hostWindow: window, remote: remote, host: local, notes: notes,
            actuator: RemoteContentActuationTests.actuator(
                hitting: { remote }, window: window, note: { notes.lines.append($0) }
            )
        )
    }

    @Test("the press goes to the host's element only, and the extension's is left alone")
    func theHostElementIsPressedAlone() throws {
        let pane = try Self.pane(hostFrame: Self.frame.offsetBy(dx: 1, dy: -1))

        let outcome = try pane.actuator.actuate(
            RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint, prefersHost: true
        ).get()

        #expect(pane.host.performed == [kAXPressAction])
        #expect(pane.remote.performed.isEmpty, "never both")
        #expect(outcome.action == "AXPress in the host's tree")
    }

    @Test("without a host element of the same role, label, action and frame, the extension's is pressed",
          arguments: ["offset", "no action", "no host window"])
    func theExtensionIsTheFallback(reason: String) throws {
        var pane = try Self.pane(
            hostHasIt: reason != "no action",
            hostFrame: reason == "offset" ? Self.frame.offsetBy(dx: 8, dy: 0) : Self.frame
        )
        if reason == "no host window" {
            // The host's window entry cannot be found by its number.
            pane = Pane(
                endpoint: pane.endpoint, hostWindow: pane.hostWindow, remote: pane.remote,
                host: pane.host, notes: pane.notes,
                actuator: RemoteContentActuationTests.actuator(
                    hitting: { pane.remote }, window: nil, note: { pane.notes.lines.append($0) }
                )
            )
        }

        let outcome = try pane.actuator.actuate(
            RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint, prefersHost: true
        ).get()

        #expect(pane.remote.performed == [kAXPressAction])
        #expect(pane.host.performed.isEmpty)
        #expect(outcome.action == kAXPressAction)
    }

    @Test("without the preference, as for a file panel, the host's tree is not searched")
    func aFilePanelKeepsItsElement() throws {
        let pane = try Self.pane()

        _ = try pane.actuator.actuate(RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint).get()

        #expect(pane.remote.performed == [kAXPressAction])
        #expect(pane.host.performed.isEmpty)
    }

    @Test("a host element that refuses is not followed by a press of the extension's")
    func aRefusedHostPressIsNotRepeated() throws {
        let pane = try Self.pane()
        pane.host.performAnswer = .failure

        #expect(throws: RemoteContentActuationRefusal.actionRefused(
            action: kAXPressAction, code: AXError.failure.rawValue
        )) {
            try pane.actuator.actuate(
                RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint, prefersHost: true
            ).get()
        }
        #expect(pane.host.performed == [kAXPressAction])
        #expect(pane.remote.performed.isEmpty)
    }

    @Test("every press logs its AXError, and cannotComplete is a delivery only where a panel's default button needs it",
          arguments: [true, false])
    func cannotCompleteIsUnverifiedInAnExtension(isExtension: Bool) throws {
        let pane = try Self.pane(hostHasIt: false)
        pane.remote.performAnswer = .cannotComplete
        let click = RemoteContentActuationTests.click(count: 1)

        let outcome = pane.actuator.actuate(click, endpoint: pane.endpoint, prefersHost: isExtension)

        if isExtension {
            #expect(throws: RemoteContentActuationRefusal.actionRefused(
                action: kAXPressAction, code: AXError.cannotComplete.rawValue
            )) { try outcome.get() }
        } else {
            #expect(try outcome.get().action == kAXPressAction)
        }
        #expect(pane.notes.lines.count == 1)
        #expect(pane.notes.lines[0].contains("AXPress on AXButton"))
        #expect(pane.notes.lines[0].contains("AXError \(AXError.cannotComplete.rawValue)"))
        pane.remote.performAnswer = .success
        _ = pane.actuator.actuate(click, endpoint: pane.endpoint, prefersHost: isExtension)
        #expect(pane.notes.lines.last?.contains("AXError 0") == true)
    }
}
