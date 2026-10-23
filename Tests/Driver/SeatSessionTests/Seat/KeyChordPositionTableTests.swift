//
//  KeyChordPositionTableTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 22/10/2026.
//

import EngineCore
import SeatCore
import Testing

/// The engine names a position by its own word and the driver by its W3C code: both must mean the same key.
@Suite("Key chord positions against the driver's key table")
struct KeyChordPositionTableTests {

    static let driverNames: [KeyChord.Name.Position: String] = [
        .home: "Home", .end: "End", .pageup: "PageUp", .pagedown: "PageDown", .forwarddelete: "Delete",
        .f1: "F1", .f2: "F2", .f3: "F3", .f4: "F4", .f5: "F5", .f6: "F6", .f7: "F7", .f8: "F8", .f9: "F9",
        .f10: "F10", .f11: "F11", .f12: "F12", .f13: "F13", .f14: "F14", .f15: "F15", .f16: "F16", .f17: "F17",
        .f18: "F18", .f19: "F19",
        .keypad0: "Numpad0", .keypad1: "Numpad1", .keypad2: "Numpad2", .keypad3: "Numpad3", .keypad4: "Numpad4",
        .keypad5: "Numpad5", .keypad6: "Numpad6", .keypad7: "Numpad7", .keypad8: "Numpad8", .keypad9: "Numpad9",
        .keypadplus: "NumpadAdd", .keypadminus: "NumpadSubtract", .keypadmultiply: "NumpadMultiply",
        .keypaddivide: "NumpadDivide", .keypaddecimal: "NumpadDecimal", .keypadequals: "NumpadEqual",
        .keypadenter: "NumpadEnter", .keypadclear: "NumLock",
    ]

    @Test("every position's virtual key is the driver's key of the same name")
    func codesMatchTheDriverTable() throws {
        #expect(Set(Self.driverNames.keys) == Set(KeyChord.Name.Position.allCases), "every position is checked")
        for position in KeyChord.Name.Position.allCases {
            let name = try #require(Self.driverNames[position])
            let key = try #require(KeyNames.key(named: name), "\(name) is not in the driver's table")
            #expect(UInt16(key.virtualKey) == position.code, "\(position.rawValue) is \(name)")
        }
    }
}
