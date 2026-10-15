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

    final class Notes {
        var lines  : [String] = []
        var settles = 0
    }

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
    static func pane(
        hostHasIt: Bool = true,
        hostFrame: CGRect = Self.frame,
        remoteRole: String = kAXButtonRole
    ) throws -> Pane {
        let surface  = FakeGeometry.identity(windowNumber: 878)
        let endpoint = try RemoteContentActuationTests.remoteEndpoint(surface: surface)
        let window   = Element("AXWindow", window: .window(878), processID: surface.processID)
        let content  = Element(kAXGroupRole, window: .window(879), processID: 7_001, parent: window)
        let remote   = Element(remoteRole, window: .window(879), processID: 7_001, parent: content,
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
                hitting: { remote }, window: window, settle: { notes.settles += 1 }, note: { notes.lines.append($0) }
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
        #expect(pane.notes.lines[1].contains("AXError 0"))
    }
    // MARK: A press the application answered and ignored

    /// A control that did not move after an AXPress that answered success.
    static func ignoring(
        role    : String = kAXButtonRole,
        before  : Bool?,
        childOffersPress: Bool = true
    ) throws -> (pane: Pane, child: Element) {
        let pane  = try Self.pane(hostHasIt: false, remoteRole: role)
        let child = Element(kAXImageRole, window: .window(879), processID: 7_001, parent: pane.remote,
                            actions: childOffersPress ? [kAXPressAction] : [])
        if role == kAXCheckBoxRole { pane.remote.toggle = before } else { pane.remote.selectedFlag = before }
        return (pane, child)
    }

    static func press(_ pane: Pane, prefersHost: Bool = true) throws -> RemoteContentActuation {
        try pane.actuator.actuate(
            RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint, prefersHost: prefersHost
        ).get()
    }

    @Test("an ignored press of a control with a state tries its child once, then asks for one posted click")
    func anIgnoredPressIsClickedOnTheHost() throws {
        let (pane, child) = try Self.ignoring(before: false)

        let outcome = try Self.press(pane)

        #expect(pane.remote.performed == [kAXPressAction])
        #expect(child.performed == [kAXPressAction], "the child is pressed once")
        #expect(outcome.needsPostedClick)
        #expect(pane.notes.settles == 2, "the state is read again after each attempt")
        #expect(pane.notes.lines.contains { $0.contains("one click is posted on the host window") })
    }

    @Test("a state that changed after the press, or after the child's, is never posted",
          arguments: ["the press", "the child"])
    func aChangedStateIsNotPosted(changedBy: String) throws {
        let (pane, child) = try Self.ignoring(before: false)
        (changedBy == "the press" ? pane.remote : child).onPerform = { _ in pane.remote.selectedFlag = true }

        let outcome = try Self.press(pane)

        #expect(!outcome.needsPostedClick)
        #expect(child.performed.count == (changedBy == "the press" ? 0 : 1))
        #expect(outcome.action == (changedBy == "the press" ? kAXPressAction : "AXPress on its child"))
    }

    @Test("without a child that presses, the parent is tried; with neither, the click is asked for")
    func theParentIsTheOtherHelper() throws {
        let (pane, child) = try Self.ignoring(before: false, childOffersPress: false)
        let group = try #require(pane.remote.parent)
        group.actions = [kAXPressAction]
        group.onPerform = { _ in pane.remote.selectedFlag = true }

        let outcome = try Self.press(pane)

        #expect(child.performed.isEmpty)
        #expect(group.performed == [kAXPressAction])
        #expect(outcome.action == "AXPress on its parent")
        #expect(!outcome.needsPostedClick)

        let (bare, _) = try Self.ignoring(before: false, childOffersPress: false)
        #expect(try Self.press(bare).needsPostedClick)
    }

    @Test("a switch that did not flip is clicked, one that flipped is not",
          arguments: [true, false])
    func aSwitchIsReadBack(flips: Bool) throws {
        let (pane, _) = try Self.ignoring(role: kAXCheckBoxRole, before: true)
        if flips { pane.remote.onPerform = { _ in pane.remote.toggle = false } }

        #expect(try Self.press(pane).needsPostedClick == !flips)
    }

    @Test("with no readable state, or one that is gone, or a segment already on, nothing more is tried",
          arguments: ["no state", "unreadable after", "already on"])
    func nothingProvesAnIgnoredPress(case reason: String) throws {
        let (pane, child) = try Self.ignoring(before: reason == "no state" ? nil : reason == "already on")
        if reason == "unreadable after" {
            pane.remote.onPerform = { _ in pane.remote.answers = false }
            pane.remote.selectedFlag = false
        }

        let outcome = try Self.press(pane)

        #expect(pane.remote.performed == [kAXPressAction], "never a second attempt")
        #expect(child.performed.isEmpty)
        #expect(!outcome.needsPostedClick)
    }

    @Test("a file panel's press is read back by nobody: no retry, no click")
    func aFilePanelIsNotRetried() throws {
        let (pane, child) = try Self.ignoring(before: false)

        let outcome = try Self.press(pane, prefersHost: false)

        #expect(pane.remote.performed == [kAXPressAction])
        #expect(child.performed.isEmpty)
        #expect(!outcome.needsPostedClick)
    }
    // MARK: A segmented selector (Appearance: Light, Dark, Auto)

    struct Appearance {
        let pane   : Pane
        let light  : Element
        let dark   : Element
        let auto   : Element
        let capsule: Element
        let actuator: RemoteContentActuator<Element>
    }

    /// The Appearance group as the 15/10/2026 dump shows it: a caption, the run Light, Dark (the
    /// only one answering AXSelected), Auto, then a caption and a button apart from the run.
    static func appearance(pressing name: String) throws -> Appearance {
        let pane    = try Self.pane(hostHasIt: false)
        let group   = try #require(pane.remote.parent)
        func button() -> Element {
            Element(kAXButtonRole, window: .window(879), processID: 7_001, parent: group, actions: [kAXPressAction])
        }
        let dark    = button()
        let auto    = button()
        _ = Element(kAXStaticTextRole, window: .window(879), processID: 7_001, parent: group)
        let capsule = button()
        dark.selectedFlag = true
        for (element, title) in [(dark, "Dark"), (auto, "Auto"), (capsule, "Capsule Shape")] {
            element.title = title
            element.frame = Self.frame
        }
        let hit = ["Light": pane.remote, "Auto": auto, "Dark": dark, "Capsule": capsule][name]!
        let notes = pane.notes
        let actuator = RemoteContentActuationTests.actuator(
            hitting: { hit }, window: pane.hostWindow, settle: { notes.settles += 1 }, note: { notes.lines.append($0) }
        )
        return Appearance(pane: pane, light: pane.remote, dark: dark, auto: auto, capsule: capsule, actuator: actuator)
    }

    static func press(_ shape: Appearance) throws -> RemoteContentActuation {
        try shape.actuator.actuate(
            RemoteContentActuationTests.click(count: 1), endpoint: shape.pane.endpoint, prefersHost: true
        ).get()
    }

    @Test("a segment whose press left the selection on another is proven ignored and clicked once",
          arguments: ["Light", "Auto"])
    func anIgnoredSegmentIsClicked(name: String) throws {
        let shape = try Self.appearance(pressing: name)

        let outcome = try Self.press(shape)

        #expect(outcome.needsPostedClick)
        #expect(shape.dark.selectedFlag == true)
        #expect(shape.pane.notes.settles == 1, "read again once: nothing to press but the segment")
    }

    @Test("a segment the press selected is not clicked", arguments: ["Light", "Auto"])
    func aSelectedSegmentIsNotClicked(name: String) throws {
        let shape = try Self.appearance(pressing: name)
        let pressed = name == "Light" ? shape.light : shape.auto
        pressed.onPerform = { _ in
            shape.dark.selectedFlag = false
            pressed.selectedFlag = true
        }

        let outcome = try Self.press(shape)

        #expect(!outcome.needsPostedClick)
        #expect(pressed.performed == [kAXPressAction])
    }

    @Test("the segment already selected is pressed once and never retried or clicked")
    func theSelectedSegmentIsLeftAlone() throws {
        let shape = try Self.appearance(pressing: "Dark")

        let outcome = try Self.press(shape)

        #expect(!outcome.needsPostedClick)
        #expect(shape.dark.performed == [kAXPressAction])
        #expect(shape.pane.notes.settles == 0)
    }

    @Test("a button apart from the run shows no state: no retry and no click")
    func aButtonOutsideTheRunShowsNoState() throws {
        let shape = try Self.appearance(pressing: "Capsule")

        let outcome = try Self.press(shape)

        #expect(!outcome.needsPostedClick)
        #expect(shape.capsule.performed == [kAXPressAction])
        #expect(shape.pane.notes.settles == 0)
        #expect(shape.pane.notes.lines.contains { $0.contains("not readable") })
    }

    @Test("a run where no segment answers AXSelected shows no state")
    func aRunWithNoSelectionShowsNoState() throws {
        let shape = try Self.appearance(pressing: "Light")
        shape.dark.selectedFlag = nil

        #expect(try !Self.press(shape).needsPostedClick)
    }
    // MARK: A press on the element that was asked for

    static func press(
        _ shape: Appearance,
        expecting label: String
    ) -> Result<RemoteContentActuation, RemoteContentActuationRefusal> {
        shape.actuator.actuate(
            RemoteContentActuationTests.click(count: 1),
            endpoint   : shape.pane.endpoint,
            prefersHost: true,
            expecting  : label
        )
    }

    @Test("Light was asked for and the point hit Dark: Light is pressed, Dark never")
    func theNamedSegmentReplacesTheWrongOne() throws {
        let shape = try Self.appearance(pressing: "Dark")
        shape.light.onPerform = { _ in
            shape.dark.selectedFlag = false
            shape.light.selectedFlag = true
        }

        let outcome = try Self.press(shape, expecting: "Light").get()

        #expect(shape.light.performed == [kAXPressAction])
        #expect(shape.dark.performed.isEmpty, "the element that was not asked for is never pressed")
        #expect(outcome.role == kAXButtonRole)
        #expect(!outcome.needsPostedClick)
        #expect(shape.pane.notes.lines.contains { $0.contains("'Dark'") && $0.contains("'Light' is pressed instead") })
    }

    @Test("a name nothing near the point answers to refuses without pressing anything")
    func aMissingNameRefuses() throws {
        let shape = try Self.appearance(pressing: "Dark")

        #expect(throws: RemoteContentActuationRefusal.wrongElement(requested: "Sepia", found: "Dark")) {
            try Self.press(shape, expecting: "Sepia").get()
        }
        for element in [shape.light, shape.dark, shape.auto, shape.capsule] { #expect(element.performed.isEmpty) }
        #expect(!RemoteContentActuationRefusal.wrongElement(requested: "a", found: "b").wasDeclinedBeforeActing,
                "an ordinary window's refusal is never posted instead")
    }

    @Test("the hit element is the asked one, however it is written: the press is unchanged",
          arguments: ["Dark", " dark ", "Dark #2", "Selected. Dark"])
    func aMatchingNamePressesTheHitElement(asked: String) throws {
        let shape = try Self.appearance(pressing: "Dark")

        let outcome = try Self.press(shape, expecting: asked).get()

        #expect(shape.dark.performed == [kAXPressAction])
        #expect(shape.light.performed.isEmpty)
        #expect(outcome.action == kAXPressAction)
        #expect(!shape.pane.notes.lines.contains { $0.contains("pressed instead") })
    }

    @Test("an element with no name of its own cannot be told apart, so it is pressed")
    func anUnnamedElementIsPressed() throws {
        let shape = try Self.appearance(pressing: "Auto")
        shape.auto.title = nil

        _ = try Self.press(shape, expecting: "Light").get()

        #expect(shape.auto.performed == [kAXPressAction])
    }

    @Test("with the name only in the host's tree, that element is pressed")
    func theHostTreeIsSearchedForTheName() throws {
        let pane = try Self.pane()
        pane.remote.title = "Dark"

        let outcome = try pane.actuator.actuate(
            RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint, prefersHost: true, expecting: "Light"
        ).get()

        #expect(pane.host.performed == [kAXPressAction])
        #expect(pane.remote.performed.isEmpty)
        #expect(outcome.action == "AXPress")
    }

    @Test("a host copy named otherwise than the pressed element is not its copy")
    func theHostCopyIsNotNamedOtherwise() throws {
        let pane = try Self.pane(hostFrame: Self.frame)
        pane.host.title = "Dark"
        pane.remote.title = "Light"

        _ = try pane.actuator.actuate(
            RemoteContentActuationTests.click(count: 1), endpoint: pane.endpoint, prefersHost: true, expecting: "Light"
        ).get()

        #expect(pane.host.performed.isEmpty, "a copy named otherwise than asked is not pressed")
        #expect(pane.remote.performed == [kAXPressAction])
    }
}
