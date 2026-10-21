//
//  HouseComposerField.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI

/// HouseComposerField is the composer's message field: an AppKit text field in the system font at 14
/// points that wraps its text and grows with it, one line at a time, up to `maximumLines`, then
/// scrolls inside. Its height is `height(of:width:)`, which the conversation also reads to animate
/// the growth. Its text starts at the frame SwiftUI gives it and wraps at that frame's width.
///
/// Return sends and Shift-Return breaks the line, as in the app's composer: both reach the field
/// editor as its `insertNewline:` command, which the field's delegate takes and tells apart by the
/// modifiers of the key being interpreted (`Coordinator.handle(_:in:modifiers:)`, testable without
/// key events). Option-Return breaks the line natively. Sending reads how far the editor has
/// scrolled the lines, while it still edits, and keeps the field editing.
///
/// `isFocused` moves the keyboard here; while `hidesPlaceholder`, an empty field shows nothing, so
/// a text leaving it does not cross its placeholder.
struct HouseComposerField: NSViewRepresentable {
    @Binding var text: String

    let placeholder     : String
    let isFocused       : FocusState<Bool>.Binding
    let hidesPlaceholder: Bool
    let link            : Link
    let onSubmit        : (_ scroll: CGFloat?) -> Void

    /// The lines the field shows before it scrolls.
    static let maximumLines = 8

    static let font = NSFont.systemFont(ofSize: 14)

    /// The height of one of the field's lines.
    static let lineHeight: CGFloat = 17

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered         = false
        field.drawsBackground    = false
        field.focusRingType      = .none
        field.font               = Self.font
        field.textColor          = .textColor
        field.usesSingleLineMode = false
        field.lineBreakMode      = .byWordWrapping
        field.cell?.wraps        = true
        field.cell?.isScrollable = false
        field.delegate           = context.coordinator
        field.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        context.coordinator.field = field
        link.coordinator          = context.coordinator
        return field
    }

    func updateNSView(
        _ field: NSTextField,
        context: Context
    ) {
        context.coordinator.parent = self
        let shown = hidesPlaceholder ? "" : placeholder
        if field.placeholderString != shown { field.placeholderString = shown }
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != text { editor.string = text }
        } else if field.stringValue != text {
            field.stringValue = text
        }
        if isFocused.wrappedValue, field.currentEditor() == nil, let window = field.window {
            window.makeFirstResponder(field)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView field: NSTextField,
        context   : Context
    ) -> CGSize? {
        let width = proposal.width ?? field.bounds.width
        return CGSize(
            width : width,
            height: Self.height(
                of   : text,
                width: width
            )
        )
    }

    /// The field's height for `text` in a field `width` points wide: one line per line the editor
    /// lays out, the empty line after a final break included, at most `maximumLines`.
    static func height(
        of text: String,
        width  : CGFloat
    ) -> CGFloat {
        let storage   = NSTextStorage(
            string    : text,
            attributes: [.font: font]
        )
        let layout    = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(
            width : max(1, width),
            height: .greatestFiniteMagnitude
        ))
        // SwiftUI places the field by its alignment rectangle: its text fills the frame SwiftUI sees.
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in
            lines += 1
        }
        if text.isEmpty || text.hasSuffix("\n") { lines += 1 }
        return CGFloat(min(
            maximumLines,
            max(1, lines)
        )) * lineHeight
    }

    // MARK: Link

    /// Link lets the composer around the field ask how far its editor has scrolled, for a send
    /// that does not come from Return.
    @MainActor
    final class Link {
        fileprivate weak var coordinator: Coordinator?

        /// How far the field's own editor has scrolled its lines up, while the field edits.
        func scroll() -> CGFloat? {
            coordinator?.scroll()
        }
    }

    // MARK: Coordinator

    /// Coordinator is the field's delegate: it keeps the text and the focus in step with the
    /// field, and takes the editor's line-break commands.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HouseComposerField

        weak var field: NSTextField?

        /// The modifier keys of the key being interpreted; tests replace it.
        var modifiers: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

        init(_ parent: HouseComposerField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused.wrappedValue { parent.isFocused.wrappedValue = true }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if parent.isFocused.wrappedValue { parent.isFocused.wrappedValue = false }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }

            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView : NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            handle(
                selector,
                in       : textView,
                modifiers: modifiers()
            )
        }

        /// Handles the editor's `selector` with `modifiers` held: Shift-Return breaks the line,
        /// Return sends with the editor's scroll; every other command goes on as usual.
        func handle(
            _ selector: Selector,
            in editor : NSTextView,
            modifiers : NSEvent.ModifierFlags
        ) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }

            if modifiers.contains(.shift) {
                editor.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit(Self.scroll(of: editor))
            }
            return true
        }

        /// How far `editor` has scrolled its lines up, while it edits the field. Its clip view sits a
        /// little off the field, so the scroll is how far the clip's bounds have moved past its frame.
        static func scroll(of editor: NSTextView) -> CGFloat? {
            guard let clip = editor.superview as? NSClipView else { return nil }

            return clip.bounds.minY - clip.frame.minY
        }

        /// How far this field's own editor has scrolled its lines up, when the field is editing.
        func scroll() -> CGFloat? {
            (field?.currentEditor() as? NSTextView).flatMap(Self.scroll(of:))
        }
    }
}
