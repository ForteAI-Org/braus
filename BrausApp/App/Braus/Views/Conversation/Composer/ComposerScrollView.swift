//
//  ComposerScrollView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import os

/// ComposerScrollView holds the composer's text view and is as tall as its
/// text, from one line up to `lineLimit`; past that the text scrolls inside
/// and the conversation above keeps its room (§13.1).
///
/// The height is measured for a width, which `ComposerField` answers SwiftUI's
/// proposal with, so a new width needs no invalidation; a change of text
/// invalidates the intrinsic content size, never from inside a layout pass.
/// The text is laid out in a scratch TextKit 1 stack at the scroll view's full
/// width, whose used rect is the measurement: below the maximum the text never
/// scrolls, so no scroller takes width, and at the maximum the height is
/// clamped, so a legacy scroller cannot feed the height back into itself.
final class ComposerScrollView: NSScrollView {

    /// The lines a field shows before it scrolls, unless its composer asks for another limit.
    nonisolated static let maximumLines = 6

    /// The field's height around one line, which the new look's composer centres in its row.
    static let oneLineHeight = ComposerScrollView().fittingHeight(forWidth: 320)

    /// The lines this field shows before it scrolls.
    var lineLimit = ComposerScrollView.maximumLines {
        didSet { cachedHeight = nil }
    }

    /// The conversation body's size, and the spec's floor (§3.3).
    static let pointSize: CGFloat = 14

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "Composer"
    )

    let textView = ComposerTextView(usingTextLayoutManager: false)

    private var measuredHeight: CGFloat = 0

    /// The last measurement, dropped when the text changes.
    private var cachedHeight: (width: CGFloat, height: CGFloat)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        drawsBackground       = false
        borderType            = .noBorder
        hasVerticalScroller   = true
        hasHorizontalScroller = false
        autohidesScrollers    = true

        let font = NSFont.systemFont(ofSize: Self.pointSize)
        textView.font                    = font
        textView.textColor               = .labelColor
        textView.typingAttributes        = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.isRichText              = false
        textView.importsGraphics         = false
        textView.allowsUndo              = true
        textView.drawsBackground         = false
        textView.textContainerInset      = NSSize(width: 0, height: 4)
        textView.minSize                 = .zero
        textView.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask        = [.width]
        textView.textContainer?.widthTracksTextView = true
        // The pill's own padding places the text; the container adds none.
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityHelp("Return sends. Shift-Return or Option-Return starts a new line. "
            + "Tab indents and Shift-Tab outdents. Control-Tab moves to the next control.")
        textView.frame = NSRect(origin: .zero, size: contentSize)
        documentView = textView

        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight)
    }

    /// The height the text asks for at the current width.
    var fittingHeight: CGFloat { fittingHeight(forWidth: bounds.width) }

    /// The height the text asks for at `width`, clamped to one line and `lineLimit`.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        if let cachedHeight, cachedHeight.width == width { return cachedHeight.height }

        let line   = lineHeight
        let inset  = textView.textContainerInset.height * 2
        let height = (min(max(textHeight(forWidth: width), line), line * CGFloat(lineLimit)) + inset)
            .rounded(.up)
        cachedHeight = (width, height)
        return height
    }

    /// Asks SwiftUI for a new height when the text now needs one. Called when
    /// the text changes, never from inside a layout pass.
    func updateHeight() {
        cachedHeight = nil
        let height   = fittingHeight
        guard height != measuredHeight else { return }

        Self.log.notice(
            "Composer height \(self.measuredHeight, privacy: .public) -> \(height, privacy: .public) at width \(self.bounds.width, privacy: .public), scroller \(self.scrollerStyle == .legacy ? "legacy" : "overlay", privacy: .public), shown \(self.verticalScroller.map { !$0.isHidden } ?? false, privacy: .public)"
        )
        measuredHeight = height
        invalidateIntrinsicContentSize()
    }

    private var lineHeight: CGFloat {
        guard let layoutManager = textView.layoutManager, let font = textView.font else { return Self.pointSize }
        return layoutManager.defaultLineHeight(for: font)
    }

    /// The text as displayed, marked text included, laid out apart from the live
    /// layout manager, so measuring never touches the text view's own layout.
    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        guard let storage = textView.textStorage else { return 0 }

        let text          = NSTextStorage(attributedString: storage)
        let layoutManager = NSLayoutManager()
        let container     = NSTextContainer(size: NSSize(
            width : width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = textView.textContainer?.lineFragmentPadding ?? 0
        layoutManager.addTextContainer(container)
        text.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
    }
}
