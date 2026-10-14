//
//  WebActuatorTests.swift
//  Braus
//

import CoreGraphics
import EngineCore
import Foundation
import Testing
import WebDriver
@testable import WebDriving

@Suite("Web actuator")
struct WebActuatorTests {

    static func types(_ events: [(String, JSONValue)]) -> [String] {
        events.compactMap { $0.1["type"]?.stringValue }
    }

    @Test("A double click is a move and two numbered press and release pairs")
    func doubleClick() throws {
        let events = try WebActuator.events(for: .click(at: CGPoint(x: 10, y: 20), count: 2))
        #expect(Self.types(events) == ["mouseMoved", "mousePressed", "mouseReleased", "mousePressed", "mouseReleased"])
        #expect(events[3].1["clickCount"]?.intValue == 2)
        #expect(events[1].1["x"]?.doubleValue == 10 && events[1].1["y"]?.doubleValue == 20)
    }

    @Test("A wheel line up scrolls the page up")
    func scroll() throws {
        let events = try WebActuator.events(for: .scroll(at: .zero, deltaY: 3))
        #expect(events.last?.1["deltaY"]?.doubleValue == -120)
    }

    @Test("Command shortcuts carry the editing command; typed text carries its text")
    func keys() throws {
        let selectAll = try WebActuator.events(for: .character("a", modifiers: .command))
        #expect(selectAll.first?.1["commands"] == ["selectAll"])
        #expect(selectAll.first?.1["text"] == nil)
        #expect(selectAll.first?.1["modifiers"]?.intValue == 4)

        let typed = try WebActuator.events(for: .type("a\n"))
        #expect(Self.types(typed) == ["keyDown", "keyUp", "keyDown", "keyUp"])
        #expect(typed[0].1["text"]?.stringValue == "a" && typed[2].1["key"]?.stringValue == "Enter")

        let end = try WebActuator.events(for: .key(code: Key.downArrow, modifiers: [.command, .shift]))
        #expect(end.first?.1["commands"] == ["moveToEndOfDocumentAndModifySelection"])
        #expect(throws: WebDrivingError.unsupportedKey(999)) { try WebActuator.events(for: .key(code: 999)) }
    }
}
