//
//  WebKeys.swift
//  Braus
//

import EngineCore
import Foundation
import WebDriver

/// WebKeys turns the engine's key gestures into `Input.dispatchKeyEvent` parameters.
///
/// The engine names keys by macOS virtual key code; a page knows DOM keys. Chrome on macOS does
/// not run editing shortcuts for synthetic events, so a Command shortcut also carries the editing
/// command it stands for, as a person's keystroke would reach the editor.
enum WebKeys {

    struct DOMKey {
        let key : String
        let code: String
        let virtualKeyCode: Int
        var text: String? = nil
    }

    static let byVirtualKey: [UInt16: DOMKey] = [
        36 : DOMKey(key: "Enter", code: "Enter", virtualKeyCode: 13, text: "\r"),
        48 : DOMKey(key: "Tab", code: "Tab", virtualKeyCode: 9),
        49 : DOMKey(key: " ", code: "Space", virtualKeyCode: 32, text: " "),
        51 : DOMKey(key: "Backspace", code: "Backspace", virtualKeyCode: 8),
        53 : DOMKey(key: "Escape", code: "Escape", virtualKeyCode: 27),
        115: DOMKey(key: "Home", code: "Home", virtualKeyCode: 36),
        116: DOMKey(key: "PageUp", code: "PageUp", virtualKeyCode: 33),
        117: DOMKey(key: "Delete", code: "Delete", virtualKeyCode: 46),
        119: DOMKey(key: "End", code: "End", virtualKeyCode: 35),
        121: DOMKey(key: "PageDown", code: "PageDown", virtualKeyCode: 34),
        123: DOMKey(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37),
        124: DOMKey(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39),
        125: DOMKey(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40),
        126: DOMKey(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38),
    ]

    /// The editing command a Command shortcut runs, by DOM key and whether Shift is held.
    static let commands: [String: String] = [
        "a": "selectAll", "c": "copy", "x": "cut", "v": "paste", "z": "undo", "Z": "redo",
        "ArrowUp": "moveToBeginningOfDocument", "ArrowDown": "moveToEndOfDocument",
        "ArrowLeft": "moveToBeginningOfLine", "ArrowRight": "moveToEndOfLine",
        "ArrowUp+shift": "moveToBeginningOfDocumentAndModifySelection",
        "ArrowDown+shift": "moveToEndOfDocumentAndModifySelection",
        "ArrowLeft+shift": "moveToBeginningOfLineAndModifySelection",
        "ArrowRight+shift": "moveToEndOfLineAndModifySelection",
    ]

    /// CDP's modifier bits: Alt 1, Control 2, Meta 4, Shift 8.
    static func bits(_ modifiers: KeyModifiers) -> Int {
        (modifiers.contains(.option) ? 1 : 0) | (modifiers.contains(.control) ? 2 : 0)
            | (modifiers.contains(.command) ? 4 : 0) | (modifiers.contains(.shift) ? 8 : 0)
    }

    /// The down and up events of one key press.
    static func press(_ key: DOMKey, modifiers: KeyModifiers) -> [JSONValue] {
        let bits = bits(modifiers)
        var down: [String: JSONValue] = [
            "type": "rawKeyDown", "key": .string(key.key), "code": .string(key.code),
            "windowsVirtualKeyCode": .number(Double(key.virtualKeyCode)), "modifiers": .number(Double(bits)),
        ]
        if modifiers.contains(.command) {
            let lookup = key.key + (modifiers.contains(.shift) && key.key.count > 1 ? "+shift" : "")
            if let command = commands[lookup] { down["commands"] = [.string(command)] }
        } else if let text = key.text, !modifiers.contains(.control), !modifiers.contains(.option) {
            down["type"] = "keyDown"
            down["text"] = .string(text)
            down["unmodifiedText"] = .string(text)
        }
        var up = down
        up["type"] = "keyUp"
        up["text"] = nil
        up["unmodifiedText"] = nil
        up["commands"] = nil
        return [.object(down), .object(up)]
    }

    static func press(code: UInt16, modifiers: KeyModifiers) throws -> [JSONValue] {
        guard let key = byVirtualKey[code] else { throw WebDrivingError.unsupportedKey(code) }
        return press(key, modifiers: modifiers)
    }

    /// A character on the key that produces it, the way the engine's shortcuts name keys.
    static func press(character: Character, modifiers: KeyModifiers) -> [JSONValue] {
        if character == "\n" || character == "\r" { return press(byVirtualKey[36]!, modifiers: modifiers) }
        if character == "\t" { return press(byVirtualKey[48]!, modifiers: modifiers) }
        let text  = String(character)
        let upper = text.uppercased()
        let code: String
        let virtualKeyCode: Int
        if let ascii = character.asciiValue, character.isLetter {
            code = "Key" + upper
            virtualKeyCode = Int(Character(upper).asciiValue ?? ascii)
        } else if let ascii = character.asciiValue, character.isNumber {
            code = "Digit" + text
            virtualKeyCode = Int(ascii)
        } else {
            code = ""
            virtualKeyCode = 0
        }
        let key = modifiers.contains(.shift) && character.isLetter ? upper : text
        return press(DOMKey(key: key, code: code, virtualKeyCode: virtualKeyCode, text: key), modifiers: modifiers)
    }
}
