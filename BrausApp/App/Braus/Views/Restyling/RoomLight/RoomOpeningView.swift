//
//  RoomOpeningView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import MetalKit

/// RoomOpeningView is a room set into the house's column: its `RoomLightView` seen through an
/// opening in the sidebar, whose wall has a thickness. The sidebar itself stays plain.
///
/// - The reveal: a band `revealWidth` wide just inside the opening, the wall's thickness, a little
///   lighter than the sidebar at the top and the sides, where it faces the light.
/// - The top shadow: a thread of shadow under the top edge, where the column overhangs the room.
/// - The sill: the bottom edge catching a little of the room's light, a thin line in its colour.
/// - The spill: the room's light on the sidebar around the opening, as from a lit window at night,
///   strongest below the sill and along the sides, fading out within `spillReach`. Its reach up and
///   to the sides stays within the gap between rooms, so it never lights a neighbour; below, it
///   passes under the rooms that follow.
///
/// The sill and the spill pulse with the room's busy flicker or waiting breath, in step with it on
/// the host clock (`RoomLightView.pulseFollowing`); under Reduce Motion they hold still. A room that
/// is off spills nothing and has no lit sill. In a room leaning left both fade toward the right as its
/// light does (`RoomLightUniforms.Shape.rightDark`), so none spills where the room is black. Every part
/// is a Core Animation layer laid out with the room's frame, so it follows a resize, a compaction and
/// a row reshaping at once, and nothing runs at rest but the pulse.
final class RoomOpeningView: NSView {

    /// The room seen through the opening.
    let room: RoomLightView

    /// What the room shows, which the opening's light follows.
    var uniforms: RoomLightUniforms {
        didSet {
            guard uniforms != oldValue else { return }
            room.uniforms = uniforms
            if uniforms.status != oldValue.status { applyLight() }
            if uniforms.lean != oldValue.lean || uniforms.camera != oldValue.camera { needsLayout = true }
        }
    }

    /// The spill's glow, the shadow of the opening's shape in the light's colour.
    let glow = CALayer()

    /// What of the spill shows across the opening: all of it, or less toward the right of a room
    /// leaning left.
    let spillMask = CAGradientLayer()

    /// The bottom edge's line of the room's light.
    let sill = CAGradientLayer()

    static let pulseKey = "openingPulse"

    /// The wall's thickness, seen inside the opening.
    static let revealWidth: CGFloat = 2

    /// How far the spill can reach from the opening, which its view covers.
    static let spillReach: CGFloat = 16

    /// The spill's glow: its blur, how far below the opening it centres, and its strength in the
    /// light of a busy room.
    static let spillRadius : CGFloat = 4
    static let spillDrop   : CGFloat = 3
    static let spillOpacity: Float   = 0.55

    /// The sill's strength in the light of a busy room.
    static let sillOpacity = 0.5

    /// The top shadow's height and its darkness at the top edge.
    static let shadowHeight : CGFloat = 5
    static let shadowOpacity: CGFloat = 0.45

    private let spillView = LayerView()
    private let edgeView  = LayerView()
    private let reveal    = CAGradientLayer()
    private let ring      = CAShapeLayer()
    private let topShadow = CAGradientLayer()

    init(
        device  : MTLDevice,
        uniforms: RoomLightUniforms
    ) {
        room = RoomLightView(
            device  : device,
            uniforms: uniforms
        )
        self.uniforms = uniforms
        super.init(frame: .zero)
        addSubview(spillView)
        addSubview(room)
        addSubview(edgeView)
        build()
        applyLight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for layer in [glow, spillMask, sill, reveal, ring, topShadow] {
            layer.contentsScale = window.backingScaleFactor
        }
        // A pulse phased to the host clock needs the layer in a window.
        applyLight()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        room.frame      = bounds
        spillView.frame = bounds.insetBy(
            dx: -Self.spillReach,
            dy: -Self.spillReach
        )
        edgeView.frame  = bounds
        place()
        CATransaction.commit()
    }

    /// The colour a room of `status` spills and lights its sill with, or nil for a room that is off,
    /// which spills nothing: the place for a faint moonlight should it land.
    static func spillColor(for status: WorkerStatus) -> CGColor? {
        guard let light = status.light else { return nil }
        return CGColor(
            srgbRed: light.red,
            green  : light.green,
            blue   : light.blue,
            alpha  : 1
        )
    }

    private func build() {
        glow.shadowRadius = Self.spillRadius
        glow.shadowOffset = CGSize(
            width : 0,
            height: -Self.spillDrop
        )
        spillMask.startPoint  = CGPoint(
            x: 0,
            y: 0.5
        )
        spillMask.endPoint    = CGPoint(
            x: 1,
            y: 0.5
        )
        spillView.layer?.addSublayer(glow)
        spillView.layer?.mask = spillMask

        // Lighter at the top, where the wall faces down into the lit room, the sidebar's at the foot.
        reveal.colors     = [Self.gray(0x23), Self.gray(0x1D), Self.gray(0x17)]
        reveal.locations  = [0, 0.5, 1]
        reveal.startPoint = CGPoint(
            x: 0.5,
            y: 1
        )
        reveal.endPoint   = CGPoint(
            x: 0.5,
            y: 0
        )
        ring.fillRule = .evenOdd
        reveal.mask   = ring
        topShadow.colors     = [CGColor(gray: 0, alpha: Self.shadowOpacity), CGColor(gray: 0, alpha: 0)]
        topShadow.startPoint = CGPoint(
            x: 0.5,
            y: 1
        )
        topShadow.endPoint   = CGPoint(
            x: 0.5,
            y: 0
        )
        sill.startPoint = CGPoint(
            x: 0,
            y: 0.5
        )
        sill.endPoint   = CGPoint(
            x: 1,
            y: 0.5
        )
        edgeView.layer?.masksToBounds = true
        edgeView.layer?.cornerCurve   = .continuous
        for layer in [topShadow, reveal, sill] {
            edgeView.layer?.addSublayer(layer)
        }
    }

    /// Lays every part out for the room's size and lean.
    private func place() {
        let size   = bounds.size
        let corner = CGFloat(RoomLightUniforms.Shape(size: size).cornerRadius)
        let reach  = Self.spillReach
        let band   = Self.revealWidth

        glow.frame      = spillView.bounds
        glow.shadowPath = CGPath(
            roundedRect : spillView.bounds.insetBy(
                dx: reach,
                dy: reach
            ),
            cornerWidth : corner,
            cornerHeight: corner,
            transform   : nil
        )
        spillMask.frame     = spillView.bounds
        spillMask.colors    = [1, 1, rightKeep].map { CGColor(gray: 0, alpha: $0) }
        spillMask.locations = fadeLocations(
            offset: reach,
            width : spillView.bounds.width
        )

        edgeView.layer?.cornerRadius = corner
        reveal.frame = edgeView.bounds
        ring.frame   = edgeView.bounds
        let path = CGMutablePath()
        path.addRoundedRect(
            in          : edgeView.bounds,
            cornerWidth : corner,
            cornerHeight: corner
        )
        if size.width > 2 * band, size.height > 2 * band {
            let inner = max(0, corner - band)
            path.addRoundedRect(
                in          : edgeView.bounds.insetBy(
                    dx: band,
                    dy: band
                ),
                cornerWidth : inner,
                cornerHeight: inner
            )
        }
        ring.path = path
        topShadow.frame = CGRect(
            x     : 0,
            y     : size.height - band - Self.shadowHeight,
            width : size.width,
            height: Self.shadowHeight
        )
        sill.frame     = CGRect(
            x     : 0,
            y     : 0,
            width : size.width,
            height: band
        )
        sill.locations = fadeLocations(
            offset: 0,
            width : size.width
        )
        applySillColors()
    }

    /// Where the right's dark range starts and ends across a layer `width` wide whose left edge lies
    /// `offset` points left of the room's, as a gradient's locations from its left edge.
    private func fadeLocations(
        offset: CGFloat,
        width : CGFloat
    ) -> [NSNumber] {
        let size  = bounds.size
        let side  = min(size.width, size.height)
        let body  = RoomLightUniforms.Shape.bodyX(
            in  : size,
            lean: uniforms.lean
        )
        let dark  = RoomLightUniforms.Shape.rightDark
        let start = (offset + body + CGFloat(dark.lowerBound) * side) / max(width, 1)
        let end   = (offset + body + CGFloat(dark.upperBound) * side) / max(width, 1)
        return [0, start, end].map { NSNumber(value: Double($0)) }
    }

    private func applySillColors() {
        guard let color = Self.spillColor(for: uniforms.status) else {
            sill.colors = nil
            return
        }
        let strength = CGFloat(Self.sillOpacity * uniforms.status.lightStrength)
        sill.colors = [1, 1, rightKeep].map { color.copy(alpha: strength * $0) ?? color }
    }

    /// What of the spill and the sill is left past the right's dark range: all of it at the centre,
    /// none in a room leaning fully left.
    private var rightKeep: CGFloat {
        1 - CGFloat(min(1, max(0, uniforms.lean)))
    }

    /// Lights the sill and the spill for the room's status and starts their pulse with the room's.
    private func applyLight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.removeAnimation(forKey: Self.pulseKey)
        sill.removeAnimation(forKey: Self.pulseKey)
        let status = uniforms.status
        let color  = Self.spillColor(for: status)
        let base   = Self.spillOpacity * Float(status.lightStrength)
        glow.shadowColor   = color
        glow.shadowOpacity = color == nil ? 0 : base
        glow.isHidden      = color == nil
        sill.isHidden      = color == nil
        applySillColors()
        CATransaction.commit()
        guard color != nil, window != nil else { return }
        if let pulse = RoomLightView.pulseFollowing(
            "shadowOpacity",
            for  : status,
            in   : glow,
            value: { NSNumber(value: base * $0) }
        ) {
            glow.add(
                pulse,
                forKey: Self.pulseKey
            )
        }
        if let pulse = RoomLightView.pulseFollowing(
            "opacity",
            for  : status,
            in   : sill,
            value: { NSNumber(value: $0) }
        ) {
            sill.add(
                pulse,
                forKey: Self.pulseKey
            )
        }
    }

    private static func gray(_ level: Int) -> CGColor {
        CGColor(
            srgbRed: CGFloat(level) / 255,
            green  : CGFloat(level) / 255,
            blue   : CGFloat(level + 3) / 255,
            alpha  : 1
        )
    }

    /// LayerView hosts layers the opening lays out itself, takes no clicks, and draws past its bounds.
    private final class LayerView: NSView {

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = CALayer()
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
