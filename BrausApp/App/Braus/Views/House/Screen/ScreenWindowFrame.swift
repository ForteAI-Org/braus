//
//  ScreenWindowFrame.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import QuartzCore

/// ScreenWindowFrame is the content of a worker's screen window: the picture and its bar
/// (`ScreenWindowContent`) inset by the neon's reach, and in that margin the neon (`NeonTube`) and
/// the shadow a window casts. Drawn by the window itself, they move and resize with it in the same
/// frame: a panel of its own trailed every drag the window server made.
/// The margin is clear but for them, and a click on it reaches nothing but just outside the picture,
/// where it resizes the picture and the window it shows, as a window's edges do. The twin of one of
/// the application's other windows wears the thin neon in a thin margin, with a smaller shadow.
final class ScreenWindowFrame: NSView {

    /// How far the main window reaches past the picture on every side; none in a Debug window check
    /// run with BRAUS_SCREEN_CHECK_NEON=none, to compare.
    static let margin: CGFloat = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAUS_SCREEN_CHECK_NEON"] == "none" { return 0 }
        #endif
        return NeonTube.Style.wide.reach
    }()

    /// How far this window reaches past its picture.
    let inset: CGFloat

    /// The neon around the picture, in the colour of who has the application.
    let tube: NeonTube

    /// The picture and its bar, given once the window's controller made them.
    var picture = NSView() {
        didSet {
            replaceSubview(
                oldValue,
                with: picture
            )
            resizeSubviews(withOldSize: bounds.size)
        }
    }

    private let shade  = NSView()
    private let glow   = NSView()

    /// A frame with the neon in `style` in a margin `inset` wide: the main window's by default.
    init(
        style: NeonTube.Style = .wide,
        inset: CGFloat = margin
    ) {
        tube       = NeonTube(
            holder: .worker,
            style : style
        )
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
        for view in [shade, glow] {
            view.wantsLayer = true
            addSubview(view)
        }
        // Under the picture, whose transparent corners show the window's shape over it.
        addSubview(picture)
        glow.layer?.addSublayer(tube.layer)
        // A window's shadow, as the still that replaces the window casts it (`LendStill`).
        // A smaller one in a thin margin, which it must stay within.
        let thin = inset < Self.margin
        shade.layer?.shadowColor   = .black
        shade.layer?.shadowOpacity = thin ? 0.35 : 0.45
        shade.layer?.shadowRadius  = thin ? 5 : 18
        shade.layer?.shadowOffset  = CGSize(
            width : 0,
            height: thin ? -2 : -8
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // Set, not resized: the window starts with no size at all.
        shade.frame   = bounds
        glow.frame    = bounds
        picture.frame = bounds.insetBy(
            dx: inset,
            dy: inset
        )
        placeMargin()
    }

    /// The window reached a display of another scale: the margin's layers, which draw nothing of
    /// their own, take it, and the neon and the shadow are placed again in that same frame.
    func backingChanged(to scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.layer?.contentsScale = scale
        glow.layer?.contentsScale  = scale
        CATransaction.commit()
        placeMargin()
    }

    /// Places the neon and the shadow around the picture at once.
    private func placeMargin() {
        // In the same transaction as the window's new size, with no animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tube.place(around: picture.frame)
        shade.layer?.shadowPath = NeonTube.rounded(
            picture.frame,
            corner: corner
        )
        CATransaction.commit()
    }

    /// The margin's layers as they stand, for the log.
    var margins: String {
        "picture \(picture.frame), neon \(tube.layer.frame) at \(tube.layer.contentsScale)x in a layer at "
            + "\(glow.layer?.contentsScale ?? 0)x, shadow layer at \(shade.layer?.contentsScale ?? 0)x"
    }

    /// Whether the neon shows.
    var showsNeon: Bool { !glow.isHidden }

    /// The window's corner radius the neon and the shadow follow, in points.
    private(set) var corner = NeonTube.windowCorner

    /// Follows a window whose corner is `corner` points round, square at zero.
    func setCorner(_ corner: CGFloat) {
        guard corner != self.corner else { return }
        self.corner = corner
        tube.setCorner(corner)
        placeMargin()
    }

    /// Shows or hides the neon and the shadow, as the window's own drawing.
    func showsMargin(_ shows: Bool) {
        shade.isHidden = !shows
        glow.isHidden  = !shows
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if edges(at: local) != nil { return self }
        return picture.frame.contains(local) ? super.hitTest(point) : nil
    }

    // MARK: Resizing

    /// Told while the person resizes the picture from just outside its edges, with the picture's
    /// frame in AppKit's screen space as the press began and now, and whether the press ended: at
    /// the first move, then at most once per `resizePace`, and once as it ends, unless it resized
    /// nothing. Nil: the edges resize nothing.
    var resizes: ((_ from: CGRect, _ to: CGRect, _ ended: Bool) -> Void)?

    /// Whether the edges resize now: only while the worker holds the application.
    var canResize: () -> Bool = { true }

    /// The least the person may make the picture.
    var minimumPicture = CGSize(
        width : 1,
        height: 1
    )

    /// Whether the person is resizing the picture now.
    private(set) var isResizing = false

    /// How far outside the picture its edges take a press, as a window's resize edges do, and the
    /// least time between two sizes told while a resize goes on.
    static let grip      : CGFloat  = 8
    static let resizePace: Duration = .milliseconds(100)

    /// Edges are the sides of the picture a resize moves; two at a corner.
    struct Edges: OptionSet, Hashable {
        let rawValue: Int

        static let left   = Edges(rawValue: 1 << 0)
        static let right  = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top    = Edges(rawValue: 1 << 3)
    }

    /// The edges a press at `point` takes, in this view's space, nil off them or while the edges
    /// resize nothing.
    private func edges(at point: CGPoint) -> Edges? {
        guard resizes != nil, canResize() else { return nil }
        return Self.edges(
            at     : point,
            picture: picture.frame,
            grip   : min(Self.grip, inset)
        )
    }

    /// The edges of a picture at `picture` that a press at `point` takes: within `grip` outside it,
    /// a corner's two near the corner; nil on the picture or farther out.
    static func edges(
        at point      : CGPoint,
        picture       : CGRect,
        grip          : CGFloat
    ) -> Edges? {
        guard grip > 0, picture.insetBy(dx: -grip, dy: -grip).contains(point), !picture.contains(point) else { return nil }
        var edges: Edges = []
        if point.x < picture.minX + grip { edges.insert(.left) } else if point.x > picture.maxX - grip { edges.insert(.right) }
        if point.y < picture.minY + grip { edges.insert(.bottom) } else if point.y > picture.maxY - grip { edges.insert(.top) }
        return edges
    }

    /// `start` with its `edges` moved by `offset`, the sides across from them staying, never less
    /// than `minimum`; whole points.
    static func resized(
        _ start  : CGRect,
        edges    : Edges,
        by offset: CGVector,
        minimum  : CGSize
    ) -> CGRect {
        var frame = start
        if edges.contains(.left) {
            frame.size.width = max(minimum.width, start.width - offset.dx).rounded()
            frame.origin.x   = start.maxX - frame.width
        } else if edges.contains(.right) {
            frame.size.width = max(minimum.width, start.width + offset.dx).rounded()
        }
        if edges.contains(.bottom) {
            frame.size.height = max(minimum.height, start.height - offset.dy).rounded()
            frame.origin.y    = start.maxY - frame.height
        } else if edges.contains(.top) {
            frame.size.height = max(minimum.height, start.height + offset.dy).rounded()
        }
        return frame
    }

    /// The pointer that says which way `edges` resize.
    private static func cursor(for edges: Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition = switch edges {
        case [.left, .top]    : .topLeft
        case [.right, .top]   : .topRight
        case [.left, .bottom] : .bottomLeft
        case [.right, .bottom]: .bottomRight
        case .left            : .left
        case .right           : .right
        case .top             : .top
        default               : .bottom
        }
        return NSCursor.frameResize(
            position  : position,
            directions: .all
        )
    }

    /// Whether this view set a resize pointer the pointer still shows.
    private var showsResizePointer = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Always, as the window is rarely key: Braus is not the active app while the person works.
        addTrackingArea(NSTrackingArea(
            rect   : .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner  : self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isResizing else { return }
        if let edges = edges(at: convert(event.locationInWindow, from: nil)) {
            Self.cursor(for: edges).set()
            showsResizePointer = true
        } else if showsResizePointer {
            NSCursor.arrow.set()
            showsResizePointer = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard !isResizing, showsResizePointer else { return }
        NSCursor.arrow.set()
        showsResizePointer = false
    }

    /// A press on the edges resizes the window with the picture until the button goes up, telling
    /// `resizes` at its pace.
    override func mouseDown(with event: NSEvent) {
        guard let window, let edges = edges(at: convert(event.locationInWindow, from: nil)) else {
            return super.mouseDown(with: event)
        }
        let start  = window.frame.insetBy(
            dx: inset,
            dy: inset
        )
        let grab   = NSEvent.mouseLocation
        var shown  = start
        var told   : ContinuousClock.Instant?
        isResizing = true
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout : NSEvent.foreverDuration,
            mode    : .eventTracking
        ) { [weak self] event, stop in
            guard let self, let event else {
                stop.pointee = true
                return
            }
            let ended   = event.type == .leftMouseUp
            let pointer = NSEvent.mouseLocation
            let picture = Self.resized(
                start,
                edges  : edges,
                by     : CGVector(
                    dx: pointer.x - grab.x,
                    dy: pointer.y - grab.y
                ),
                minimum: minimumPicture
            )
            if picture != shown {
                shown = picture
                window.setFrame(
                    picture.insetBy(
                        dx: -inset,
                        dy: -inset
                    ),
                    display: true
                )
            }
            if ended {
                stop.pointee = true
                isResizing   = false
                // A press that never resized writes nothing.
                if told != nil || shown != start { resizes?(start, shown, true) }
            } else if shown != start, told.map({ .now - $0 >= Self.resizePace }) ?? true {
                told = .now
                resizes?(start, shown, false)
            }
        }
        isResizing = false
    }
}
