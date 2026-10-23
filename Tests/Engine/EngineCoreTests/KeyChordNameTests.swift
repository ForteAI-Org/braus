//
//  KeyChordNameTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 22/10/2026.
//

@testable import EngineCore
import Testing

/// The words a tool may give `press_key`: every one parses, prints back as itself, and presses the key it names.
/// Pro Tools found the gap: Shift-Option-= and the keypad's plus were refused as unknown keys.
@Suite("Key chord names")
struct KeyChordNameTests {

    @Test("every listed word parses and prints back as itself")
    func everyWordRoundTrips() throws {
        for word in KeyChord.Name.all {
            let name = try #require(KeyChord.Name(word), "\(word) does not parse")
            #expect(name.word == word)
        }
        #expect(Set(KeyChord.Name.all).count == KeyChord.Name.all.count, "no word is listed twice")
    }

    @Test("punctuation is a meaning pressed through the layout, with its modifiers held")
    func punctuationGoesByCharacter() throws {
        for mark in ["=", "-", "[", "]", "\\", ";", "'", ",", ".", "`"] {
            let name = try #require(KeyChord.Name(mark))
            #expect(name == .character(Character(mark)))
            #expect(KeyChord(name).gesture == .character(Character(mark), modifiers: []))
        }
        let increase = KeyChord(.character("="), modifiers: [.shift, .option])
        #expect(increase.gesture == .character("=", modifiers: [.shift, .option]))
        #expect(increase.description == "opt+shift+=")
    }

    @Test("a position is pressed by its virtual key, whatever the layout")
    func positionsGoByCode() throws {
        #expect(KeyChord.Name("keypadplus") == .position(.keypadplus))
        #expect(KeyChord.Name("F5") == .position(.f5), "names are read lowercased, like return or tab")
        #expect(KeyChord(.position(.keypadplus), modifiers: .control).gesture == .key(code: 69, modifiers: .control))
        #expect(KeyChord(.position(.pagedown)).gesture == .key(code: 121, modifiers: []))
        #expect(KeyChord(.position(.f2)).gesture == .key(code: 120, modifiers: []))
        let codes = KeyChord.Name.Position.allCases.map(\.code)
        #expect(Set(codes).count == codes.count, "two positions never share a key")
    }

    @Test("a keypad digit is never the main block's digit")
    func keypadDigitsAreTheirOwnKeys() {
        #expect(KeyChord.Name("keypad7") == .position(.keypad7))
        #expect(KeyChord.Name("7") == .character("7"))
        #expect(KeyChord(.position(.keypad7)).gesture != KeyChord(.character("7")).gesture)
    }

    @Test("an unknown word is refused, not guessed")
    func unknownWordsAreRefused() {
        for word in ["+", "f20", "keypad", "pgdn", "equal", "==", "é", ""] {
            #expect(KeyChord.Name(word) == nil, "\(word) should be refused")
        }
    }
}

/// The keys the names now admit keep the guards of the keys they behave like.
@Suite("Key chord policy for the new names")
struct KeyChordPolicyTests {

    @Test("Command with forward Delete deletes like Command with Delete")
    func forwardDeleteIsDestructive() {
        #expect(ActionPolicy.isDestructive(KeyChord(.position(.forwarddelete), modifiers: .command)))
        #expect(ActionPolicy.isDestructive(KeyChord(.delete, modifiers: .command)))
        #expect(!ActionPolicy.isDestructive(KeyChord(.position(.forwarddelete))))
    }

    @Test("Command with a period dismisses like Escape, a bare period does not")
    func commandPeriodIsEscape() {
        #expect(ActionPolicy.dismissesLikeEscape(KeyChord(.escape)))
        #expect(ActionPolicy.dismissesLikeEscape(KeyChord(.character("."), modifiers: .command)))
        #expect(!ActionPolicy.dismissesLikeEscape(KeyChord(.character("."))))
        #expect(!ActionPolicy.dismissesLikeEscape(KeyChord(.position(.keypaddecimal), modifiers: .command)))
    }

    @Test("Command with Q or W is still refused, and no punctuation reaches it")
    func quitAndCloseStayRefused() {
        #expect(ActionPolicy.closesTheTarget(KeyChord(.character("q"), modifiers: .command)))
        #expect(ActionPolicy.closesTheTarget(KeyChord(.character("w"), modifiers: [.command, .shift])))
        #expect(!ActionPolicy.closesTheTarget(KeyChord(.character("="), modifiers: .command)))
    }
}
