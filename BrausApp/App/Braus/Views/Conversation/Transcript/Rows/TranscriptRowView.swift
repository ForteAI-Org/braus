//
//  TranscriptRowView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptRowView draws one prepared row, block by block, and lets its
/// text be selected.
///
/// A recycled view: `configure` replaces everything it shows, including the
/// selection, which the controller owns in logical terms (`TranscriptSelection`)
/// so a view that scrolls away and comes back as another row keeps nothing of
/// the old one. A press or drag on text is handed to the controller with its
/// window location: the view that took the press may be showing another row
/// before the drag ends, so it keeps no selection state of its own. Main actor only.
///
/// Nothing here runs on its own: a link opens and a code block is copied only
/// on a click or on the controller's keyboard action, and nothing is fetched.
@MainActor
final class TranscriptRowView: NSView {

    typealias TextStack = (NSTextStorage, NSLayoutManager, NSTextContainer)

    /// A press, then either a drag that selects text from where it began, or
    /// a click that selects the bubble. A click never starts a text selection.
    enum PointerPhase {
        case press
        case dragStart
        case drag
        case click(count: Int, modifiers: NSEvent.ModifierFlags)
    }

    /// Called with a press, drag or click on the row's bubble and its window location.
    var onPointer: ((PointerPhase, NSPoint) -> Void)?

    /// Called when the row's own action runs: a tool run expands or folds.
    var onActivate: (() -> Void)?

    /// Called when a click or VoiceOver runs one of the row's actions.
    var onAction: ((RowAction) -> Void)?

    /// Asked for the row's context menu on a right or Control click, with the
    /// block and the row offset of the character under the pointer, if any.
    var onMenu: ((_ block: Int?, _ offset: Int?) -> NSMenu?)?

    /// Called when VoiceOver's Reply runs on a message row.
    var onReply: (() -> Void)?

    /// How strongly the bubble is tinted, from 1 as a quote leads to it down to
    /// 0, where it rests; `flash()` animates it through the view's animator.
    @objc dynamic var flashAmount: CGFloat = 0 { didSet { needsDisplay = true } }

    var isFocusedRow = false { didSet { needsDisplay = true } }

    /// Whether a focused row draws its outline: the keyboard's focus is outlined, a click's is not.
    var showsFocusRing = false { didSet { if showsFocusRing != oldValue { needsDisplay = true } } }

    private var isOutlined: Bool { isFocusedRow && showsFocusRing }

    /// True when the whole message is selected as a bubble: drawn lighter, and spoken as selected.
    var isBubbleSelected = false {
        didSet {
            guard isBubbleSelected != oldValue else { return }
            setAccessibilitySelected(isBubbleSelected)
            needsDisplay = true
        }
    }

    /// The action the keyboard has reached inside the focused row, outlined.
    var focusedAction: RowAction? { didSet { needsDisplay = true } }

    private var row        : PreparedRow?

    /// Where the row's text is laid out, in the row's flipped coordinates; nil before a row is shown.
    var textFrame: CGRect? { row?.geometry.text }

    private var style      = TranscriptStyle()
    private var workerName = ""
    private var avatar     : NSImage?
    private(set) var selection: NSRange?
    private var pressLocation : NSPoint?
    private var didDrag       = false
    private(set) var stacks: [TextStack?] = []
    private var ranges     : [NSRange] = []
    private var thinkingBlob: ThinkingBlobView?

    /// The quote's name and excerpt, laid out as `RowPreparation` measured them.
    private var quoteStacks: (name: TextStack?, text: TextStack?) = (nil, nil)

    /// Each finished code block's copy icon, by block, which turns into a check once its code is copied.
    private var copyIcons  : [Int: NSImageView] = [:]
    private var copiedReset: Task<Void, Never>?

    /// A tool line's disclosure chevron, which turns to point down while the line is open.
    private var chevron    : NSImageView?

    /// The spinner before a running tool line's words.
    private var spinner    : NSProgressIndicator?

    /// The words arriving over the row, and the first character the row leaves undrawn meanwhile.
    private var reveals    : [WordReveal] = []
    private var veiledFrom : Int?

    /// True while the pointer is over a tool line's summary, which then lifts like a button.
    private var isHoveringLine = false { didSet { if isHoveringLine != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    /// The footer's time, made and measured once per row and text size rather than on every draw:
    /// formatting the date and measuring it again cost most of a row's drawing.
    private var footerTime: (key: FooterTimeKey, text: NSAttributedString, size: CGSize)?

    private struct FooterTimeKey: Equatable {
        let item     : TranscriptItem.ID
        let date     : Date
        let pointSize: CGFloat
    }

    override var isFlipped: Bool { true }

    func configure(
        _ row     : PreparedRow,
        style     : TranscriptStyle,
        workerName: String,
        avatar    : NSImage?,
        selection : NSRange?
    ) {
        // The same row again, as a streamed reply grows, keeps the laid out stacks of its unchanged blocks.
        let previous    = self.row?.item.id == row.item.id && self.style == style ? self.row : nil
        let previousRow = self.row?.item.id == row.item.id ? self.row : nil
        let oldStacks   = stacks
        if previousRow == nil { isHoveringLine = false }
        if previousRow == nil { showReply(false, animated: false) }
        if previousRow == nil { endReveals() }
        let oldLine     = self.row.flatMap(Self.lineFrame(of:))
        let oldQuote    = self.row?.geometry.quote
        if previousRow == nil { flashAmount = 0 }
        self.row        = row
        self.style      = style
        self.workerName = workerName
        self.avatar     = avatar
        self.selection  = selection
        ranges          = row.text.blockRanges
        stacks          = zip(row.text.blocks, row.geometry.blockTexts).enumerated().map { index, pair in
            let (block, frame) = pair
            if let previous, oldStacks.indices.contains(index), previous.text.blocks.indices.contains(index),
               previous.text.blocks[index] == block, previous.geometry.blockTexts[index].width == frame.width {
                return oldStacks[index]
            }
            return block.kind == .rule ? nil : RowPreparation.textStack(block.attributed(style), width: frame.width)
        }
        quoteStacks     = Self.quoteStacks(
            of        : row,
            workerName: workerName,
            style     : style
        )
        showThinking(row)
        showSpinner(row)
        showCopyIcons(row, keepsCopied: previous != nil)
        showChevron(row, wasExpanded: Self.isExpanded(previousRow))
        configureAccessibility(row)
        // Only when the summary or the quote moved or came and went: every other update keeps the same cursor.
        if Self.lineFrame(of: row) != oldLine || row.geometry.quote != oldQuote {
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    /// The blob of a thinking row, in its text's place; hidden for any other row, which stops it.
    private func showThinking(_ row: PreparedRow) {
        guard row.item.kind == .thinking else {
            thinkingBlob?.isHidden = true
            return
        }
        let blob = thinkingBlob ?? ThinkingBlobView()
        if thinkingBlob == nil {
            thinkingBlob = blob
            addSubview(blob)
        }
        // The blob is the bubble's light grey, as its worker's colour is the room's.
        blob.tint     = NSColor(white: 0.92, alpha: 1)
        blob.frame    = row.geometry.text
        blob.isHidden = false
    }

    /// Whether `row` is an open tool line, or nil when it is no tool line at all.
    private static func isExpanded(_ row: PreparedRow?) -> Bool? {
        guard case .toolRun(_, let isExpanded, _)? = row?.item.kind else { return nil }
        return isExpanded
    }

    /// The chevron over a tool line's disclosure slot. The same line opening or
    /// closing turns it with a short rotation; Reduce Motion turns it at once.
    private func showChevron(_ row: PreparedRow, wasExpanded: Bool?) {
        guard let isExpanded = Self.isExpanded(row), let frame = disclosureSlot(in: row) else {
            chevron?.isHidden = true
            return
        }
        let icon = chevron ?? makeChevron()
        chevron = icon
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.toolPointSize * 0.8,
                                                               weight: .semibold)
        icon.isHidden = false
        // A rotated view's frame is its bounding box, so it is placed upright and turned after.
        icon.frameCenterRotation = 0
        icon.frame = frame
        // Flipped, a positive rotation turns clockwise: the chevron that pointed right points down.
        let angle: CGFloat = isExpanded ? 90 : 0
        guard let wasExpanded, wasExpanded != isExpanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            icon.frameCenterRotation = angle
            return
        }
        icon.frameCenterRotation = wasExpanded ? 90 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            icon.animator().frameCenterRotation = angle
        }
    }

    private func makeChevron() -> NSImageView {
        let icon = NSImageView()
        icon.image            = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling     = .scaleProportionallyDown
        icon.wantsLayer       = true
        // The row's expanded state speaks for it, and its press goes to the row.
        icon.setAccessibilityElement(false)
        addSubview(icon)
        return icon
    }

    /// A square at the end of the room the tool line's summary keeps after its text, on its one line,
    /// so a summary cut short still ends with the chevron.
    private func disclosureSlot(in row: PreparedRow) -> CGRect? {
        guard let summary = row.geometry.blocks.first else { return nil }
        let side = RowGeometry.disclosureSide(style)
        return CGRect(x: summary.maxX - side, y: summary.midY - side / 2, width: side, height: side).integral
    }

    /// The copy icons of the row's finished code blocks. Another row starts
    /// them as copy icons; the same row growing keeps a check still showing.
    private func showCopyIcons(_ row: PreparedRow, keepsCopied: Bool) {
        if !keepsCopied { copiedReset?.cancel() }
        let blocks = Set(row.text.blocks.indices.filter {
            row.text.blocks[$0].isCompleteCode && row.geometry.blocks.indices.contains($0)
        })
        for (index, icon) in copyIcons where !blocks.contains(index) {
            icon.removeFromSuperview()
            copyIcons[index] = nil
        }
        for index in blocks {
            let icon = copyIcons[index] ?? makeCopyIcon()
            copyIcons[index] = icon
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.captionPointSize, weight: .medium)
            if !keepsCopied { icon.image = Self.copySymbol(copied: false) }
        }
        placeCopyIcons()
    }

    private func makeCopyIcon() -> NSImageView {
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling     = .scaleProportionallyDown
        // The row's Copy action speaks for it, and its press goes to the row.
        icon.setAccessibilityElement(false)
        addSubview(icon)
        return icon
    }

    private func placeCopyIcons() {
        guard let row else { return }
        for (index, icon) in copyIcons where row.geometry.blocks.indices.contains(index) {
            icon.frame = RowGeometry.copyControl(in: row.geometry.blocks[index], style: style)
                .offsetBy(dx: drift(of: row), dy: 0)
        }
    }

    /// Turns the block's copy icon into a check, then back, as the system's off-up symbol replace does.
    func showCopied(block: Int) {
        guard let icon = copyIcons[block] else { return }

        Self.replace(
            icon,
            with: Self.copySymbol(copied: true)
        )
        copiedReset?.cancel()
        copiedReset = Task { [weak icon] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard let icon else { return }

            Self.replace(
                icon,
                with: Self.copySymbol(copied: false)
            )
        }
    }

    /// Swaps `icon`'s symbol for `image` in Core Animation, as the off-up replace shows it: the old symbol
    /// shrinks and fades where it is while the new one grows in, rising a little; a cross-fade under
    /// Reduce Motion. A symbol effect (`setSymbolImage(_:contentTransition:)`) would leave RenderBox
    /// drawing at every frame any window animates, for the rest of the process.
    static func replace(
        _ icon    : NSImageView,
        with image: NSImage
    ) {
        let old = HouseTranscriptStill.image(of: icon)
        icon.image = image
        guard let layer = icon.layer, let parent = layer.superlayer, let old else { return }

        let reduces = HouseMotion.reducesMotion
        let ghost   = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame           = layer.frame
        ghost.contents        = old
        ghost.contentsGravity = .resize
        ghost.opacity         = 0
        parent.addSublayer(ghost)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let leaving = CABasicAnimation(keyPath: "opacity")
        leaving.fromValue      = 1
        leaving.toValue        = 0
        leaving.duration       = 0.18
        leaving.timingFunction = CAMediaTimingFunction(name: .easeIn)
        ghost.add(
            leaving,
            forKey: "opacity"
        )
        let entering = CABasicAnimation(keyPath: "opacity")
        entering.fromValue = 0
        entering.toValue   = 1
        entering.duration  = 0.2
        layer.add(
            entering,
            forKey: "replaceOpacity"
        )
        if !reduces {
            let shrinking = CABasicAnimation(keyPath: "transform.scale")
            shrinking.fromValue      = 1
            shrinking.toValue        = 0.5
            shrinking.duration       = 0.18
            shrinking.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ghost.add(
                shrinking,
                forKey: "scale"
            )
            // The view's layer turns about its corner: scale about its middle, from a little lower.
            let middle  = CGPoint(
                x: layer.bounds.midX,
                y: layer.bounds.midY
            )
            var start   = CATransform3DMakeTranslation(-middle.x, -middle.y, 0)
            start       = CATransform3DConcat(start, CATransform3DMakeScale(0.5, 0.5, 1))
            start       = CATransform3DConcat(start, CATransform3DMakeTranslation(middle.x, middle.y + (parent.isGeometryFlipped ? 3 : -3), 0))
            let growing = CASpringAnimation(keyPath: "transform")
            growing.fromValue = NSValue(caTransform3D: start)
            growing.toValue   = NSValue(caTransform3D: CATransform3DIdentity)
            growing.stiffness = 300
            growing.damping   = 20
            growing.duration  = growing.settlingDuration
            layer.add(
                growing,
                forKey: "replaceTransform"
            )
        }
        CATransaction.commit()
    }

    private static func copySymbol(copied: Bool) -> NSImage {
        let name = copied ? "checkmark" : "doc.on.doc"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    /// Tints the bubble for a moment and fades the tint out, so the message a
    /// quote led to is found at a glance. Nothing moves, so Reduce Motion keeps it.
    func flash() {
        guard let row, RowGeometry.shape(of: row.item.kind) == .bubble else { return }

        flashAmount = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration       = 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().flashAmount = 0
        }
    }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "flashAmount" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    /// The quote's name and excerpt laid out at the width they were measured
    /// at, in the label's colours.
    private static func quoteStacks(
        of row    : PreparedRow,
        workerName: String,
        style     : TranscriptStyle
    ) -> (name: TextStack?, text: TextStack?) {
        guard let quote = row.item.quote, let frame = row.geometry.quoteText else { return (nil, nil) }

        let name       = row.geometry.quoteName.map { _ in
            RowPreparation.textStack(
                RowPreparation.quoteName(
                    workerName,
                    style: style,
                    color: .labelColor
                ),
                width       : frame.width,
                maximumLines: 1
            )
        }
        let text       = RowPreparation.textStack(
            RowPreparation.quoteExcerpt(
                quote,
                style: style,
                color: .secondaryLabelColor
            ),
            width       : frame.width,
            maximumLines: RowGeometry.quoteLines
        )
        return (name, text)
    }

    private static func isPersonMessage(_ row: PreparedRow) -> Bool {
        if case .personMessage = row.item.kind { true } else { false }
    }

    /// How far a row's parts move from where they were placed: a live resize
    /// widens the row before its parts are placed again off the main thread.
    /// The column is centred, so a row's parts follow its start, the person's
    /// bubble its end and a divider its centre, on whole points.
    private func drift(of row: PreparedRow) -> CGFloat {
        let placed = RowGeometry.column(rowWidth: row.geometry.rowWidth)
        let now    = RowGeometry.column(rowWidth: bounds.width)
        switch row.item.kind {
        case .personMessage:
            return (now.start + now.width - placed.start - placed.width).rounded()
        case .daySeparator, .contextSeparator, .activityNotShown:
            return (now.start + now.width / 2 - placed.start - placed.width / 2).rounded()
        default:
            return now.start - placed.start
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard changed else { return }
        placeCopyIcons()
        needsDisplay = true
    }

    /// The copy icons and the chevron take no press of their own; the row decides what a press on them does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSImageView ? self : hit
    }

    /// Replaces the drawn selection and nothing else.
    func show(selection range: NSRange?) {
        guard range != selection else { return }
        selection    = range
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let geometry = row.geometry
        let isPerson: Bool
        if case .personMessage = row.item.kind { isPerson = true } else { isPerson = false }

        // ponytail: only drawing follows the drift; a press during it hits where the parts were placed.
        let drift = drift(of: row)
        if drift != 0 { NSGraphicsContext.current?.cgContext.translateBy(x: drift, y: 0) }
        drawSurface(row, geometry: geometry, isPerson: isPerson)
        if let avatar, let frame = geometry.avatar { avatar.draw(in: frame) }
        if let header = geometry.header { drawName(row, in: header) }
        if let footer = geometry.footer { drawTime(row, in: footer, isPerson: isPerson) }
        for index in row.text.blocks.indices
        where geometry.blocks.indices.contains(index) && geometry.blocks[index].offsetBy(dx: drift, dy: 0).intersects(dirtyRect) {
            drawBlock(at: index, of: row)
        }
        if let frame = geometry.badge, let badge = DeliveryBadge(row.item.kind) { draw(badge, in: frame) }
    }

    private func drawBlock(at index: Int, of row: PreparedRow) {
        let block = row.text.blocks[index]
        let frame = row.geometry.blocks[index]
        let text  = row.geometry.blockTexts[index]

        switch block.kind {
        case .code(_, true):
            TranscriptColors.codeSurface.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            drawCopyControl(in: frame, isFocused: focusedAction == .copyBlock(index: index))
        case .quote:
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height).fill()
        case .rule:
            NSColor.separatorColor.setFill()
            NSRect(x: frame.minX, y: frame.midY.rounded(), width: frame.width, height: 1).fill()
        case .toolSteps:
            // The steps lift off the background as a card, so they read apart from the replies.
            let path   = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
            let shadow = NSShadow()
            shadow.shadowColor      = .black.withAlphaComponent(0.14)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset     = NSSize(width: 0, height: -1)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            TranscriptColors.cardSurface.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            if let (storage, manager, _) = stacks[index] {
                drawDividers(
                    card   : frame,
                    text   : text,
                    storage: storage,
                    manager: manager
                )
            }
        default:
            break
        }
        guard let (_, manager, container) = stacks[index] else { return }
        // A code block in the person's bubble has its own light surface, so it selects as any text does.
        drawSelection(in: text, block: index, clip: frame)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: text.origin)
        manager.drawGlyphs(forGlyphRange: unveiledGlyphs(of: index, in: glyphs), at: text.origin)
        if case .openLink(_, index, let range)? = focusedAction {
            strokeFocus(around: range, in: index, origin: text.origin)
        }
    }

    /// A hairline in the gap above every step but the first, across the card inside its padding.
    private func drawDividers(
        card   : CGRect,
        text   : CGRect,
        storage: NSTextStorage,
        manager: NSLayoutManager
    ) {
        let source = storage.string as NSString
        var starts: [Int] = []
        var start = 0
        while start < source.length {
            starts.append(start)
            start = NSMaxRange(source.paragraphRange(for: NSRange(location: start, length: 0)))
        }
        let scale = window?.backingScaleFactor ?? 2
        let inset = RowGeometry.toolCardPadding.width
        NSColor.separatorColor.setFill()
        for line in starts.dropFirst() {
            // Halfway between the step above and this one.
            let above = manager.lineFragmentUsedRect(
                forGlyphAt    : manager.glyphIndexForCharacter(at: line - 1),
                effectiveRange: nil
            )
            let below = manager.lineFragmentUsedRect(
                forGlyphAt    : manager.glyphIndexForCharacter(at: line),
                effectiveRange: nil
            )
            let y = ((text.minY + (above.maxY + below.minY) / 2) * scale).rounded() / scale
            NSRect(x: card.minX + inset, y: y, width: max(0, card.width - 2 * inset), height: 1 / scale).fill()
        }
    }

    private func drawSurface(_ row: PreparedRow, geometry: RowGeometry, isPerson: Bool) {
        let surface = geometry.surface
        switch RowGeometry.shape(of: row.item.kind) {
        case .bubble:
            drawBubble(row, geometry: geometry, isPerson: isPerson)

        case .card:
            let path = NSBezierPath(roundedRect: surface, xRadius: 8, yRadius: 8)
            TranscriptColors.cardSurface.setFill()
            path.fill()
            if case .executionFailed = row.item.kind {
                NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            } else {
                NSColor.separatorColor.setStroke()
            }
            path.lineWidth = 1
            path.stroke()
            if isOutlined { strokeFocus(path) }

        case .line, .divider:
            // A quiet caption with no surface of its own; focus still outlines it.
            let frame = geometry.text.insetBy(dx: -6, dy: -2)
            if isHoveringLine, let line = Self.lineFrame(of: row) {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: line, xRadius: 6, yRadius: 6).fill()
            }
            drawToolDot(row)
            if isOutlined { strokeFocus(NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)) }
        }
    }

    /// The quote at the bubble's top: a rounded block a shade darker than the
    /// bubble, its bar in the colour of whoever wrote the quoted message, the
    /// worker's name when it was theirs, and at most two lines of the excerpt.
    private func drawQuote(of row: PreparedRow) {
        guard let quote = row.item.quote, let block = row.geometry.quote else { return }

        let path = NSBezierPath(
            roundedRect: block,
            xRadius    : RowGeometry.quoteCornerRadius,
            yRadius    : RowGeometry.quoteCornerRadius
        )
        TranscriptColors.quoteSurface(isOnAccent: false).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        TranscriptColors.quoteBar(
            quotesPerson: quote.isFromPerson,
            isOnAccent  : false
        ).setFill()
        NSRect(
            x     : block.minX,
            y     : block.minY,
            width : RowGeometry.quoteBar,
            height: block.height
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        let placed = [(quoteStacks.name, row.geometry.quoteName), (quoteStacks.text, row.geometry.quoteText)]
        for case let ((_, manager, container)?, frame?) in placed {
            let glyphs = manager.glyphRange(for: container)
            manager.drawGlyphs(
                forGlyphRange: glyphs,
                at           : frame.origin
            )
        }
        if focusedAction == .openQuote { strokeFocus(path) }
    }

    /// Focus is an outline, so it reads without colour (§3.3).
    private func strokeFocus(_ path: NSBezierPath) {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func strokeFocus(around range: NSRange, in block: Int, origin: CGPoint) {
        guard let (_, manager, container) = stacks[block] else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        manager.enumerateEnclosingRects(
            forGlyphRange           : glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in                      : container
        ) { rect, _ in
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -1)
            self.strokeFocus(NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3))
        }
    }

    /// The icon is a subview; the keyboard's focus on it is outlined here.
    private func drawCopyControl(in block: CGRect, isFocused: Bool) {
        guard isFocused else { return }
        let frame = RowGeometry.copyControl(in: block, style: style)
        strokeFocus(NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4))
    }

    private func drawName(_ row: PreparedRow, in frame: CGRect) {
        guard let name = TranscriptWording.header(for: row.item, workerName: workerName).name else { return }
        NSAttributedString(
            string    : name,
            attributes: [.font: style.textFont(ofSize: style.captionPointSize, weight: .bold),
                         .foregroundColor: NSColor.labelColor]
        ).draw(at: frame.origin)
    }

    /// The time sits at the bubble's inner corner, in from its edge, past the
    /// badge when there is one: bottom left under the person's, bottom right under the worker's.
    private func drawTime(_ row: PreparedRow, in frame: CGRect, isPerson: Bool) {
        guard row.item.endsGroup, style.showsTimes else { return }
        let key = FooterTimeKey(
            item     : row.item.id,
            date     : row.item.date,
            pointSize: style.captionPointSize - 1
        )
        if footerTime?.key != key {
            // The colour is the dynamic tertiary label, so a kept string still follows the appearance.
            let text = NSAttributedString(
                string    : TranscriptWording.header(for: row.item, workerName: workerName).time,
                attributes: [.font: style.textFont(ofSize: key.pointSize),
                             .foregroundColor: NSColor.tertiaryLabelColor]
            )
            footerTime = (key, text, text.size())
        }
        guard let (_, time, size) = footerTime else { return }
        let badge = row.geometry.badge.map { $0.width + 4 } ?? 0
        let x     = isPerson ? frame.minX + RowGeometry.footerInset + badge
                             : frame.maxX - RowGeometry.footerInset - badge - size.width
        time.draw(at: CGPoint(x: x, y: frame.midY - size.height / 2))
    }

    /// The badge's symbol: its shape carries the meaning, and a stopped or
    /// failed turn's is also a red disc so it is seen; the unsent clock stays quiet.
    private func draw(_ badge: DeliveryBadge, in frame: CGRect) {
        let colors: [NSColor] = badge == .interrupted ? [.white, .systemRed] : [.secondaryLabelColor]
        let configuration = NSImage.SymbolConfiguration(pointSize: frame.height, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let symbol = NSImage(systemSymbolName: badge.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        symbol.draw(in: frame)
    }

    /// The part of the row's selection inside `block`, kept within its frame, in the system's colour.
    private func drawSelection(in frame: CGRect, block: Int, clip: CGRect) {
        guard let (storage, manager, container) = stacks[block] else { return }
        // The stack outlives a selection change when its block is unchanged, so an old inversion is cleared first.
        manager.removeTemporaryAttribute(.foregroundColor,
                                         forCharacterRange: NSRange(location: 0, length: storage.length))
        guard let selection, selection.length > 0 else { return }
        let local = NSIntersectionRange(selection, ranges[block])
        guard local.length > 0 else { return }
        let characters = NSRange(location: local.location - ranges[block].location, length: local.length)
        let glyphs     = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        NSColor.selectedTextBackgroundColor.setFill()
        manager.enumerateEnclosingRects(
            forGlyphRange             : glyphs,
            withinSelectedGlyphRange  : NSRange(location: NSNotFound, length: 0),
            in                        : container
        ) { rect, _ in
            rect.offsetBy(dx: frame.minX, dy: frame.minY).intersection(clip).fill()
        }
    }

    // MARK: Selection and action

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let row, let block = copyControl(at: point, in: row) {
            onAction?(.copyBlock(index: block))
            return
        }
        // The quote goes to its message; the press first takes the keyboard, as on any row.
        if let quote = row?.geometry.quote, quote.contains(point) {
            onPointer?(.press, event.locationInWindow)
            onAction?(.openQuote)
            return
        }
        guard let row, blockCharacter(at: point, boundary: true) != nil || row.geometry.surface.contains(point)
        else {
            super.mouseDown(with: event)
            return
        }
        // Only the summary opens and folds the line: a click in the opened card leaves it open.
        if let line = Self.lineFrame(of: row), line.contains(point), event.clickCount == 1 {
            // A press first, as on any row, so the keyboard comes here and no outline is drawn.
            onPointer?(.press, event.locationInWindow)
            onActivate?()
            return
        }
        pressLocation = event.locationInWindow
        didDrag       = false
        onPointer?(.press, event.locationInWindow)
    }

    /// Past the viewport's edge the drag scrolls it; the controller keeps the
    /// selection's far end on whichever row is then under the pointer.
    override func mouseDragged(with event: NSEvent) {
        guard let press = pressLocation else { return }
        if !didDrag, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) > 2 {
            didDrag = true
            onPointer?(.dragStart, press)
        }
        guard didDrag else { return }
        autoscroll(with: event)
        onPointer?(.drag, event.locationInWindow)
    }

    /// A click that did not drag opens the link under it, as its explicit
    /// action, or else selects the bubble.
    override func mouseUp(with event: NSEvent) {
        defer { pressLocation = nil }
        guard !didDrag, pressLocation != nil, let row else { return }
        if let (block, offset) = blockCharacter(at: convert(event.locationInWindow, from: nil)),
           let action = RowAction.actions(in: row.text).first(where: {
               if case .openLink(_, block, let range) = $0 { NSLocationInRange(offset, range) } else { false }
           }) {
            onAction?(action)
            return
        }
        onPointer?(.click(count: event.clickCount, modifiers: event.modifierFlags), event.locationInWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let hit = blockCharacter(at: convert(event.locationInWindow, from: nil))
        return onMenu?(hit?.block, hit.map { ranges[$0.block].location + $0.offset })
    }

    override func accessibilityPerformPress() -> Bool {
        guard let row, Self.isToolRun(row) else { return false }
        onActivate?()
        return true
    }

    /// Worded when assistive technology asks, never on configure: a tool line's
    /// label reads every step's JSON, and a resize configures each visible row per frame.
    override func accessibilityLabel() -> String? {
        guard let row else { return nil }
        return TranscriptWording.accessibilityLabel(
            for: row.item, workerName: workerName, content: row.item.messageID != nil ? row.text.string : nil
        )
    }

    private func copyControl(at point: CGPoint, in row: PreparedRow) -> Int? {
        row.text.blocks.indices.first { index in
            row.text.blocks[index].isCompleteCode && row.geometry.blocks.indices.contains(index)
                && RowGeometry.copyControl(in: row.geometry.blocks[index], style: style)
                    .insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    /// The character boundary in the row's text nearest `point`, anywhere in
    /// the row: above its text is the start, below it the end, and between
    /// two blocks the start of the lower one.
    func nearestCharacter(to point: CGPoint) -> Int {
        guard let row else { return 0 }
        let texts = row.geometry.blocks.indices.filter { stacks.indices.contains($0) && stacks[$0] != nil }
        guard let block = texts.first(where: { point.y < row.geometry.blocks[$0].maxY }) else {
            return row.length
        }
        guard point.y >= row.geometry.blocks[block].minY, let (storage, manager, container) = stacks[block] else {
            return ranges[block].location
        }
        let frame = row.geometry.blockTexts[block]
        var fraction: CGFloat = 0
        let index = manager.characterIndex(
            for                                : CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            in                                 : container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return ranges[block].location + min(storage.length, index + (fraction > 0.5 ? 1 : 0))
    }

    /// The block under `point` and the character in it: the character hit,
    /// or with `boundary` the nearest insertion point.
    private func blockCharacter(at point: CGPoint, boundary: Bool = false) -> (block: Int, offset: Int)? {
        guard let row else { return nil }
        let frames = row.geometry.blocks
        guard let block = frames.indices.first(where: {
            stacks.indices.contains($0) && stacks[$0] != nil && frames[$0].insetBy(dx: -4, dy: -4).contains(point)
        }), let (storage, manager, container) = stacks[block] else { return nil }
        let frame = row.geometry.blockTexts[block]
        var fraction: CGFloat = 0
        let index = manager.characterIndex(
            for                                : CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            in                                 : container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return (block, min(storage.length, index + (boundary && fraction > 0.5 ? 1 : 0)))
    }

    private static func isToolRun(_ row: PreparedRow) -> Bool {
        if case .toolRun = row.item.kind { true } else { false }
    }

    /// A tool line's summary, where it opens and folds, and what the hover lights.
    private static func lineFrame(of row: PreparedRow) -> CGRect? {
        guard isToolRun(row), let summary = row.geometry.blocks.first else { return nil }
        return summary.insetBy(dx: -6, dy: -2)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect   : .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner  : self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isHoveringLine = row.flatMap(Self.lineFrame(of:))?.contains(point) ?? false
        if showsReplyButton { showReply(replyArea?.contains(point) ?? false) }
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringLine = false
        showReply(false)
    }

    // MARK: Bubble and tool line

    /// A bubble: the person's dark grey, lighter toward its top, the worker's a faint veil with a
    /// hairline edge, each with its tight corner toward its author. A selected one is lighter, a
    /// flashed one tinted.
    private func drawBubble(
        _ row   : PreparedRow,
        geometry: RowGeometry,
        isPerson: Bool
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let surface = geometry.surface
        let path    = BubblePath.housePath(
            surface      : surface,
            tightTrailing: isPerson
        )
        context.saveGState()
        context.addPath(path)
        context.clip()
        if isPerson, let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors     : [NSColor(white: 0.24, alpha: 1).cgColor, NSColor(white: 0.17, alpha: 1).cgColor] as CFArray,
            locations  : [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start  : CGPoint(x: surface.minX + surface.width * 0.33, y: surface.minY),
                end    : CGPoint(x: surface.minX + surface.width * 0.67, y: surface.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.setFillColor(NSColor.white.withAlphaComponent(0.04).cgColor)
            context.fill(surface)
        }
        if isBubbleSelected {
            context.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            context.fill(surface)
        } else if flashAmount > 0 {
            context.setFillColor((isPerson ? NSColor.white : .controlAccentColor)
                .withAlphaComponent(0.3 * flashAmount).cgColor)
            context.fill(surface)
        }
        if !isPerson {
            // Clipped to the bubble, a two point stroke leaves a one point edge inside it.
            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
            context.setLineWidth(2)
            context.strokePath()
        }
        context.restoreGState()
        if isOutlined, !isBubbleSelected { strokeFocus(NSBezierPath(cgPath: path)) }
        drawQuote(of: row)
    }

    /// A finished tool line's quiet dot, before its words; a running one has a spinner there.
    private func drawToolDot(_ row: PreparedRow) {
        guard case .toolRun(_, _, .some) = row.item.kind, let slot = toolIndicator(of: row) else { return }

        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: slot).fill()
    }

    /// Where a tool line's spinner or dot sits, before its summary.
    private func toolIndicator(of row: PreparedRow) -> CGRect? {
        guard Self.isToolRun(row), let summary = row.geometry.blocks.first else { return nil }

        let side = RowGeometry.houseToolIndicator
        return CGRect(
            x     : row.geometry.surface.minX,
            y     : (summary.midY - side / 2).rounded(),
            width : side,
            height: side
        )
    }

    /// The spinner of a tool line whose turn runs; hidden for any other row, which stops it.
    private func showSpinner(_ row: PreparedRow) {
        guard case .toolRun(_, _, nil) = row.item.kind, let slot = toolIndicator(of: row) else {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
            return
        }
        let spinner = self.spinner ?? makeSpinner()
        spinner.frame    = slot.offsetBy(dx: drift(of: row), dy: 0)
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    private func makeSpinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style                  = .spinning
        spinner.controlSize            = .mini
        spinner.isDisplayedWhenStopped = false
        // The row speaks for its tool line.
        spinner.setAccessibilityElement(false)
        addSubview(spinner)
        self.spinner = spinner
        return spinner
    }

    // MARK: Words arriving

    /// Fades the row's words in from character `start` of its text on, each from transparent,
    /// blurred and a little low, one after another (`WordReveal`), as a reply arrives. The words are not drawn by the row until they are all in. Nothing plays under
    /// Reduce Motion, for a row that is not on screen, or past `WordReveal.wordLimit` words.
    func revealWords(from start: Int) {
        guard !HouseMotion.reducesMotion, window != nil, let row else { return }

        let words = wordFrames(of: row, from: start)
        guard !words.isEmpty, words.count <= WordReveal.wordLimit, let picture = textPicture(of: row) else { return }

        let reveal = WordReveal(frame: bounds)
        addSubview(reveal)
        reveals.append(reveal)
        veiledFrom   = min(veiledFrom ?? start, start)
        needsDisplay = true
        reveal.play(
            words,
            in: picture
        ) { [weak self, weak reveal] in
            guard let self, let reveal else { return }

            reveal.removeFromSuperview()
            reveals.removeAll { $0 === reveal }
            if reveals.isEmpty {
                veiledFrom   = nil
                needsDisplay = true
            }
        }
    }

    /// Ends every reveal at once, as the view takes another row.
    private func endReveals() {
        reveals.forEach { $0.removeFromSuperview() }
        reveals    = []
        veiledFrom = nil
    }

    /// The glyphs of block `index` the row draws: all of `glyphs` but the words still arriving.
    private func unveiledGlyphs(
        of index : Int,
        in glyphs: NSRange
    ) -> NSRange {
        guard let veiledFrom, ranges.indices.contains(index), let (_, manager, _) = stacks[index] else { return glyphs }

        let shown = max(0, min(ranges[index].length, veiledFrom - ranges[index].location))
        return manager.glyphRange(
            forCharacterRange   : NSRange(location: 0, length: shown),
            actualCharacterRange: nil
        )
    }

    /// The frame of each word of `row`'s text from character `start` on: each run of characters
    /// between spaces, as its block lays it out.
    private func wordFrames(
        of row    : PreparedRow,
        from start: Int
    ) -> [CGRect] {
        var frames: [CGRect] = []
        let blank = CharacterSet.whitespacesAndNewlines
        for (index, range) in ranges.enumerated() where NSMaxRange(range) > start && row.geometry.blockTexts.indices.contains(index) {
            guard let (storage, manager, container) = stacks[index] else { continue }

            let origin = row.geometry.blockTexts[index].origin
            let text   = storage.string as NSString
            var word: Int?
            for offset in max(0, start - range.location)...text.length {
                let isBlank = offset == text.length || UnicodeScalar(text.character(at: offset)).map(blank.contains) ?? false
                if !isBlank, word == nil { word = offset }
                guard isBlank, let first = word else { continue }

                word = nil
                let glyphs = manager.glyphRange(
                    forCharacterRange   : NSRange(location: first, length: offset - first),
                    actualCharacterRange: nil
                )
                frames.append(manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return frames
    }

    /// The row's text alone, every word drawn, on a clear picture of the row's size.
    private func textPicture(of row: PreparedRow) -> CGImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds),
              let drawing = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        let context = drawing.cgContext
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, stack) in stacks.enumerated() where row.geometry.blockTexts.indices.contains(index) {
                guard let (_, manager, container) = stack else { continue }

                manager.drawGlyphs(
                    forGlyphRange: manager.glyphRange(for: container),
                    at           : row.geometry.blockTexts[index].origin
                )
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    // MARK: Reply button

    /// Whether a message offers Reply in a round button beside its bubble, on its outer side, while
    /// the pointer is over the bubble or the button, while the conversation's flights ask for it.
    var showsReplyButton = false {
        didSet { if !showsReplyButton { showReply(false, animated: false) } }
    }

    private var replyButton: NSButton?

    /// The reply button's side, and the room between it and the bubble.
    private static let replySide: CGFloat = 28
    private static let replyGap : CGFloat = 10

    /// Where the reply button sits, beside a message's bubble on its outer side; nil for any other row.
    private var replySlot: CGRect? {
        guard let row, row.item.messageID != nil, RowGeometry.shape(of: row.item.kind) == .bubble else { return nil }

        let surface = row.geometry.surface.offsetBy(dx: drift(of: row), dy: 0)
        let x       = Self.isPersonMessage(row) ? surface.minX - Self.replyGap - Self.replySide : surface.maxX + Self.replyGap
        return CGRect(x: x, y: surface.midY - Self.replySide / 2, width: Self.replySide, height: Self.replySide)
    }

    /// The bubble, the gap and the button: the area that keeps the button shown.
    private var replyArea: CGRect? {
        guard let row, let slot = replySlot else { return nil }

        return row.geometry.surface.offsetBy(dx: drift(of: row), dy: 0).union(slot)
    }

    /// Shows or hides the reply button, fading it unless `animated` is false.
    private func showReply(_ shown: Bool, animated: Bool = true) {
        guard shown || replyButton != nil, let button = replyButton ?? makeReplyButton() else { return }

        if shown, let slot = replySlot { button.frame = slot }
        if shown { button.isHidden = false }
        guard animated else {
            button.alphaValue = shown ? 1 : 0
            button.isHidden   = !shown
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            button.animator().alphaValue = shown ? 1 : 0
        } completionHandler: { [weak button] in
            MainActor.assumeIsolated {
                if let button, button.alphaValue == 0 { button.isHidden = true }
            }
        }
    }

    private func makeReplyButton() -> NSButton? {
        guard let symbol = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: "Reply")
        else { return nil }

        let button = NSButton(image: symbol, target: self, action: #selector(replyPressed))
        button.isBordered             = false
        button.symbolConfiguration    = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.contentTintColor       = .labelColor
        button.wantsLayer             = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        button.layer?.cornerRadius    = Self.replySide / 2
        button.toolTip                = "Reply"
        button.isHidden               = true
        button.alphaValue             = 0
        // The row's own Reply action speaks for it to VoiceOver.
        button.setAccessibilityElement(false)
        addSubview(button)
        replyButton = button
        return button
    }

    @objc
    private func replyPressed() {
        onReply?()
    }

    override func resetCursorRects() {
        if let row, let line = Self.lineFrame(of: row) { addCursorRect(line, cursor: .pointingHand) }
        if let quote = row?.geometry.quote { addCursorRect(quote, cursor: .pointingHand) }
    }

    // MARK: Accessibility

    /// The row reads as a whole; a reply with structure also lists its blocks,
    /// so headings are headings and code is named as code (§3.3). The row's
    /// actions are VoiceOver actions, and a message also offers Reply. Nothing
    /// is announced when a row changes.
    private func configureAccessibility(_ row: PreparedRow) {
        let isMessage = row.item.messageID != nil
        setAccessibilityElement(true)
        setAccessibilityRole(Self.isToolRun(row) ? .button : .staticText)

        let isStructured = isMessage && row.text.blocks.contains { $0.kind != .text }
        setAccessibilityChildren(isStructured ? blockElements(row) : nil)

        let text    = row.text
        let actions = RowAction.actions(in: row).map { action in
            NSAccessibilityCustomAction(name: TranscriptWording.action(action, in: text)) { [weak self] in
                self?.onAction?(action)
                return true
            }
        }
        let reply   = NSAccessibilityCustomAction(name: "Reply") { [weak self] in
            self?.onReply?()
            return true
        }
        setAccessibilityCustomActions(isMessage ? [reply] + actions : actions)
    }

    private func blockElements(_ row: PreparedRow) -> [NSAccessibilityElement] {
        zip(row.text.blocks, row.geometry.blocks).compactMap { block, frame -> NSAccessibilityElement? in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame)
            switch block.kind {
            case .rule:
                return nil
            case .heading:
                // macOS 15 has no heading role; the heading is read as text there.
                if #available(macOS 26, *) {
                    element.setAccessibilityRole(.headingRole)
                } else {
                    element.setAccessibilityRole(.staticText)
                }
                element.setAccessibilityLabel(block.string)
            case .code(let language, _):
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityLabel(TranscriptWording.codeBlock(language: language))
                element.setAccessibilityValue(block.string)
            case .table:
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityRoleDescription("table")
                element.setAccessibilityValue(block.string.replacingOccurrences(of: "\n", with: ", "))
            case .text, .quote, .toolSummary, .toolSteps:
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityValue(block.string)
            }
            return element
        }
    }
}
