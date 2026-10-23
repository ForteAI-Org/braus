//
//  InputRequest.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// InputRequest is one input a model asks the engine to deliver beyond a click: text into a field, a
/// key into the window, a scroll, a drag, or an item of a target's contextual menu. Every target it
/// names is resolved live against this instant's scene, like an `ActionRequest`'s, and the effect is
/// judged by perceiving again.
public struct InputRequest: Sendable, Equatable {

    /// What the request delivers. Named targets are element ids or labels.
    public enum Input: Sendable, Equatable {
        /// Clicks the field `into` to focus it and types `text`: over everything it holds when
        /// `replacing`, else after it.
        case typeText(String, into: String, replacing: Bool)
        /// Inserts one payload at the current focus and selection without clicking or selecting.
        /// Only a readable focused value matching `expecting` can verify the result.
        case insertText(String, expecting: String? = nil)
        /// Presses a key `times` times into the window, the chord's modifiers held around each press.
        case pressKey(KeyChord, times: Int)
        /// Turns the wheel by `lines`, positive up, over a target, or over the window's centre when nil.
        case scroll(lines: Int, over: String?)
        /// Drags from one target to another target, or by an offset in points.
        case drag(from: String, to: DragEnd)
        /// Right-clicks a target and chooses the item titled `item` in the contextual menu it opens.
        case contextMenu(on: String, item: String)
    }

    /// Where a drag ends: on another target, or at an offset in points from where it starts.
    public enum DragEnd: Sendable, Equatable {
        case target(String)
        case offset(dx: Double, dy: Double)
    }

    /// The most presses one key request repeats, so a single request never holds the window for long.
    public static let maximumKeyPresses = 20

    /// The most wheel lines one scroll turns.
    public static let maximumScrollLines = 50

    public var processID: pid_t
    public var bundleID: String
    public var appName: String
    public var input: Input
    /// A panel name that disambiguates a shared label, for every target the input names.
    public var section: String?
    /// A rehearsal: resolve and report what would happen, perform nothing.
    public var isDryRun: Bool
    /// The field the call classified ordinary before its first write (`ActionEngine.classify`), for a text
    /// input: the engine types only into it, or stops. Nil for an input the call did not bind.
    public var binding: TextTargetBinding?
    /// The call withholds this input's text from every record (W1): the engine quotes no value of the field in its
    /// answer, in any form, and keeps the expected and observed texts out of its check, whose verdict stands.
    public var withholdsText: Bool

    public init(
        processID: pid_t,
        bundleID : String,
        appName  : String,
        input    : Input,
        section  : String? = nil,
        isDryRun : Bool = false,
        binding  : TextTargetBinding? = nil,
        withholdsText: Bool = false
    ) {
        self.processID = processID
        self.bundleID  = bundleID
        self.appName   = appName
        self.input     = input
        self.section   = section
        self.isDryRun  = isDryRun
        self.binding   = binding
        self.withholdsText = withholdsText
    }
}

/// KeyChord is one key the engine presses by name and the modifiers held around it. A named key is a
/// position, the same on every layout; a letter, a digit or a punctuation mark is a meaning, pressed
/// wherever the installed layout puts it; a slash or a tilde on its own is typed, like text.
public struct KeyChord: Sendable, Equatable, CustomStringConvertible {

    /// The keys a chord can name: the ones that navigate and submit, the positions of the function
    /// row, the keypad and the navigation block, the letters, digits and punctuation a shortcut is
    /// written with, and the slash and tilde that open a file panel's Go to Folder.
    public enum Name: Sendable, Equatable {
        case `return`, tab, escape, space, delete
        case left, right, up, down
        /// A key that has no character of its own, or whose character another key also types: F5,
        /// the keypad's plus beside the main block's equal, Page Down. Pressed by its position.
        case position(Position)
        /// A letter a to z, a digit 0 to 9, lowercase, a punctuation mark of the main block, or `/` or `~`.
        case character(Character)

        /// The positions a chord names by their own word. The keypad digits are positions, never the
        /// main block's digits: an application tells them apart (Pro Tools nudges with the keypad's
        /// plus and minus), so a shortcut written for one is never pressed on the other.
        public enum Position: String, Sendable, Equatable, CaseIterable {
            case home, end, pageup, pagedown, forwarddelete
            case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19
            case keypad0, keypad1, keypad2, keypad3, keypad4, keypad5, keypad6, keypad7, keypad8, keypad9
            case keypadplus, keypadminus, keypadmultiply, keypaddivide, keypaddecimal, keypadequals
            case keypadenter, keypadclear

            /// The macOS virtual key of the position, the same on every layout.
            public var code: UInt16 {
                switch self {
                    case .home          : 115
                    case .end           : 119
                    case .pageup        : 116
                    case .pagedown      : 121
                    case .forwarddelete : 117
                    case .f1            : 122
                    case .f2            : 120
                    case .f3            : 99
                    case .f4            : 118
                    case .f5            : 96
                    case .f6            : 97
                    case .f7            : 98
                    case .f8            : 100
                    case .f9            : 101
                    case .f10           : 109
                    case .f11           : 103
                    case .f12           : 111
                    case .f13           : 105
                    case .f14           : 107
                    case .f15           : 113
                    case .f16           : 106
                    case .f17           : 64
                    case .f18           : 79
                    case .f19           : 80
                    case .keypad0       : 82
                    case .keypad1       : 83
                    case .keypad2       : 84
                    case .keypad3       : 85
                    case .keypad4       : 86
                    case .keypad5       : 87
                    case .keypad6       : 88
                    case .keypad7       : 89
                    case .keypad8       : 91
                    case .keypad9       : 92
                    case .keypadplus    : 69
                    case .keypadminus   : 78
                    case .keypadmultiply: 67
                    case .keypaddivide  : 75
                    case .keypaddecimal : 65
                    case .keypadequals  : 81
                    case .keypadenter   : 76
                    case .keypadclear   : 71
                }
            }
        }

        /// The key a tool names: `return`, `left`, `a`, `7`. Nil for anything else.
        public init?(_ name: String) {
            switch name.lowercased() {
                case "return": self = .return
                case "tab"   : self = .tab
                case "escape": self = .escape
                case "space" : self = .space
                case "delete": self = .delete
                case "left"  : self = .left
                case "right" : self = .right
                case "up"    : self = .up
                case "down"  : self = .down
                case let word:
                    if let position = Position(rawValue: word) {
                        self = .position(position)
                        return
                    }
                    guard word.count == 1, let character = word.first,
                          ("a"..."z").contains(character) || ("0"..."9").contains(character)
                              || Self.typed.contains(character) || Self.punctuation.contains(character)
                    else { return nil }
                    self = .character(character)
            }
        }

        /// Every name a tool may use, in the order a person reads them.
        public static var all: [String] {
            ["return", "tab", "escape", "space", "delete", "left", "right", "up", "down"]
                + Position.allCases.map(\.rawValue)
                + "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
                + Self.punctuation.map(String.init)
                + Self.typed.map(String.init)
        }

        /// The punctuation of the main block, pressed wherever the installed layout puts it, as a
        /// letter is: `=` with Shift and Option is the key that types `=`, with those modifiers held.
        static let punctuation: [Character] = ["=", "-", "[", "]", "\\", ";", "'", ",", ".", "`"]

        /// The characters pressed by typing them rather than by finding their key. A file panel
        /// out of process takes a plain key and drops every shortcut, so `/` is how its Go to
        /// Folder opens there; on an Italian layout it also needs Shift, which a letter never does.
        static let typed: [Character] = ["/", "~"]

        /// The name a tool writes and a sentence reads.
        public var word: String {
            switch self {
                case .return              : "return"
                case .tab                 : "tab"
                case .escape              : "escape"
                case .space               : "space"
                case .delete              : "delete"
                case .left                : "left"
                case .right               : "right"
                case .up                  : "up"
                case .down                : "down"
                case .position(let position): position.rawValue
                case .character(let value): String(value)
            }
        }
    }

    public let key: Name
    public let modifiers: KeyModifiers

    public init(_ key: Name, modifiers: KeyModifiers = []) {
        self.key       = key
        self.modifiers = modifiers
    }

    /// `cmd+shift+n`, the modifiers in the order a menu prints them.
    public var description: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("ctrl") }
        if modifiers.contains(.option)  { words.append("opt") }
        if modifiers.contains(.shift)   { words.append("shift") }
        if modifiers.contains(.command) { words.append("cmd") }
        return (words + [key.word]).joined(separator: "+")
    }

    /// The gesture that presses this chord once.
    public var gesture: Gesture {
        switch key {
            case .return              : .key(code: Key.return, modifiers: modifiers)
            case .tab                 : .key(code: Key.tab, modifiers: modifiers)
            case .escape              : .key(code: Key.escape, modifiers: modifiers)
            case .space               : .key(code: Key.space, modifiers: modifiers)
            case .delete              : .key(code: Key.delete, modifiers: modifiers)
            case .left                : .key(code: Key.leftArrow, modifiers: modifiers)
            case .right               : .key(code: Key.rightArrow, modifiers: modifiers)
            case .up                  : .key(code: Key.upArrow, modifiers: modifiers)
            case .down                : .key(code: Key.downArrow, modifiers: modifiers)
            case .position(let position): .key(code: position.code, modifiers: modifiers)
            case .character(let value) where modifiers.isEmpty && Name.typed.contains(value):
                .type(String(value))
            case .character(let value): .character(value, modifiers: modifiers)
        }
    }
}
