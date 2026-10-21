//
//  HouseComposerFieldTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("HouseComposerField")
@MainActor
struct HouseComposerFieldTests {

    @Test("Shift-Return reaching the editor as insertNewline: breaks the line and sends nothing")
    func shiftReturnBreaksTheLine() {
        var sent   = 0
        let editor = Self.editor("Line one")
        let field  = Self.coordinator { _ in sent += 1 }
        field.modifiers = { .shift }
        #expect(field.control(
            NSTextField(),
            textView   : editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(editor.string == "Line one\n")
        #expect(sent == 0)
    }

    @Test("Return reaching the editor as insertNewline: sends and leaves the text as it is")
    func returnSends() {
        var sent   = 0
        let editor = Self.editor("Line one")
        let field  = Self.coordinator { _ in sent += 1 }
        field.modifiers = { [] }
        #expect(field.control(
            NSTextField(),
            textView   : editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(editor.string == "Line one")
        #expect(sent == 1)
    }

    @Test("Other commands go on as usual")
    func otherCommandsPass() {
        let field = Self.coordinator { _ in }
        #expect(!field.handle(
            #selector(NSResponder.insertTab(_:)),
            in       : Self.editor(""),
            modifiers: []
        ))
    }

    @Test("The field grows a line at a time up to eight, the line after a final break included")
    func heightFollowsTheLines() {
        let line = HouseComposerField.lineHeight
        #expect(HouseComposerField.height(of: "", width: 300) == line)
        #expect(HouseComposerField.height(of: "One line", width: 300) == line)
        #expect(HouseComposerField.height(of: "One\nTwo\nThree", width: 300) == line * 3)
        #expect(HouseComposerField.height(of: "One\n", width: 300) == line * 2)
        #expect(HouseComposerField.height(
            of   : Array(repeating: "Line", count: 12).joined(separator: "\n"),
            width: 300
        ) == line * CGFloat(HouseComposerField.maximumLines))
    }

    private static func editor(_ text: String) -> NSTextView {
        let editor = NSTextView()
        editor.string = text
        editor.setSelectedRange(NSRange(
            location: (text as NSString).length,
            length  : 0
        ))
        return editor
    }

    private static func coordinator(
        onSubmit: @escaping (CGFloat?) -> Void
    ) -> HouseComposerField.Coordinator {
        HouseComposerField.Coordinator(HouseComposerField(
            text            : .constant(""),
            placeholder     : "Message",
            isFocused       : FocusState<Bool>().projectedValue,
            hidesPlaceholder: false,
            link            : HouseComposerField.Link(),
            onSubmit        : onSubmit
        ))
    }
}
