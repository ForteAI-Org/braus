//
//  MascotLayer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import QuartzCore

/// MascotLayer draws a worker's mascot: a body of dark graphite metal in the worker's shape, lit by
/// its status light, with two brows that morph from one expression to the next.
///
/// Every body is the same metal and only its outline tells workers apart: the outline
/// RoomLight.metal shades in a room, under the same gradients, so a worker looks the same in and out
/// of rooms. The bounds are the sphere's square; other shapes reach past them by up to their
/// `ShapeOutline.extent`, and the brows sit on the shape's inscribed circle, its face.
///
/// The brows are white enamel inlaid in the metal: a little lighter at the top, where the light falls,
/// a little shaded at the bottom, with a thread of shadow under them where they meet the body.
///
/// The head never changes colour for an outcome, since the room light tells it; only a worker that
/// is off dims the body and greys the brows. Every motion asks `RestylingMotion` first: under
/// Reduce Motion a morph is a cut, the brows turn without travel and the head does not breathe.
/// Nonisolated like `CALayer`, whose overrides it needs; the methods that read `RestylingMotion`
/// are main-actor isolated, and the layer belongs to the main thread like every tree the app owns.
nonisolated final class MascotLayer: CALayer {

    /// The worker's shape. The brows follow it even when another renderer draws the body.
    var shape = WorkerShape.circle {
        didSet {
            guard shape != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Where a tilted room's camera shows the brows, or nil where they keep their place on the face.
    var projectedFace: RoomCamera.Face? {
        didSet {
            guard projectedFace != oldValue else { return }
            withoutActions { placeBrows() }
            scheduleBehaviourRefresh()
        }
    }

    /// How far above the face's centre the brows' line sits, as a share of the face's width.
    static let browLift = 0.5 - 0.36

    /// What the worker is doing: a worker that is off dims and greys.
    var status = WorkerStatus.free {
        didSet { applyColors() }
    }

    /// Whether this layer draws the sphere. False when another renderer draws the body underneath
    /// and only the brows belong here.
    var drawsBody = true {
        didSet { withoutActions { body.isHidden = !drawsBody } }
    }

    let leftBrow  = CAShapeLayer()
    let rightBrow = CAShapeLayer()

    /// The thread of shadow under each brow where the enamel meets the body: the brow's outline a
    /// little lower, beneath it, morphing with it.
    let leftContact  = CAShapeLayer()
    let rightContact = CAShapeLayer()

    /// The copies that shade each brow's enamel below its top band, by brow: one half way down in the
    /// middle tone, one a full step down in the shaded bottom tone, each clipped to the brow by a mask
    /// that morphs with it. In a room the top band and the middle one also take the room's light.
    private var leftLight : [CAShapeLayer] = []
    private var rightLight: [CAShapeLayer] = []

    private let body       = CALayer()
    private let silhouette = CAShapeLayer()
    private let base       = CAGradientLayer()
    private let shading    = CAGradientLayer()
    private let bounce     = CAGradientLayer()
    private let sheen      = CAGradientLayer()
    private let dimming    = CALayer()

    /// The expression last shown.
    private var state = BrowState.idle

    /// The outline the brows hold: `state`, or `look` while an idle mascot looks to the right.
    private var heldBrows = BrowState.idle

    private var yaw  : Double = 0
    private var pitch: Double = 0

    /// Which brow leads the next calm change; it alternates, as the prototype's random order varies.
    private var leftLeads = true

    override init() {
        super.init()
        for gradient in [base, shading, bounce, sheen] {
            gradient.type = .radial
            body.addSublayer(gradient)
        }
        body.addSublayer(dimming)
        body.mask = silhouette
        addSublayer(body)

        // Graphite, as the room's Metal body paints it before dimming it for its reflections.
        base.colors = [
            Self.color(hex: 0x2D2D32),
            Self.color(hex: 0x222226),
            Self.color(hex: 0x1F1F23),
        ]
        base.locations = [0, 0.44, 1]

        // Darkens the lower half and the sides for volume, lightly, so the edge reads diffuse as the
        // room's Metal body does.
        shading.colors = [
            CGColor(gray: 0, alpha: 0),
            CGColor(gray: 0, alpha: 0.2),
        ]
        shading.locations = [0.55, 1]

        // A barely visible neutral bounce on the lowest tenth, inside the outline: no light without a source.
        bounce.locations = [0, 0.2, 0.34]
        bounce.colors    = [
            CGColor(gray: 1, alpha: 0.05),
            CGColor(gray: 1, alpha: 0.025),
            CGColor(gray: 1, alpha: 0),
        ]

        // A broad, faint, warm sheen upper left with no hard core, as the lamp's reflection on the
        // room's Metal body, so the mascot keeps its volume and looks like the same object.
        let warm = CGColor(
            srgbRed: 1,
            green  : 0.92,
            blue   : 0.84,
            alpha  : 1
        )
        sheen.colors = [
            warm.copy(alpha: 0.26) as Any,
            warm.copy(alpha: 0.11) as Any,
            warm.copy(alpha: 0) as Any,
        ]
        sheen.locations = [0, 0.45, 1]

        dimming.backgroundColor = CGColor(gray: 0, alpha: 1)

        let sides = [
            (leftBrow, leftContact, BrowOutlines.bundled.left),
            (rightBrow, rightContact, BrowOutlines.bundled.right),
        ]
        for (brow, contact, outlines) in sides {
            for layer in [contact, brow] {
                layer.bounds = CGRect(
                    x     : 0,
                    y     : 0,
                    width : Self.artboard.width,
                    height: Self.artboard.height
                )
                layer.path = outlines[.idle].map(Self.path)
                addSublayer(layer)
            }
            contact.fillColor = CGColor(gray: 0, alpha: Self.contactOpacity)
        }
        leftLight  = Self.lightCopies(over: leftBrow)
        rightLight = Self.lightCopies(over: rightBrow)
        applyColors()
    }

    /// The two copies under `brow`'s lit edge, a half step and a full `litEdge` step down.
    private static func lightCopies(over brow: CAShapeLayer) -> [CAShapeLayer] {
        [0.5, 1].map { share in
            let step = litEdge * share
            let copy = CAShapeLayer()
            copy.frame    = brow.bounds.offsetBy(dx: 0, dy: -step)
            copy.path     = brow.path
            copy.isHidden = true
            let mask = CAShapeLayer()
            mask.frame = copy.bounds.offsetBy(dx: 0, dy: step)
            mask.path  = brow.path
            copy.mask  = mask
            brow.addSublayer(copy)
            return copy
        }
    }

    /// Every layer that holds `brow`'s outline: the brow, its contact shadow, its light copies and
    /// their masks.
    func outlineLayers(of brow: CAShapeLayer) -> [CAShapeLayer] {
        let copies = lightCopies(of: brow)
        return [brow, contact(of: brow)] + copies + copies.compactMap { $0.mask as? CAShapeLayer }
    }

    /// The contact shadow under `brow`.
    func contact(of brow: CAShapeLayer) -> CAShapeLayer {
        brow === leftBrow ? leftContact : rightContact
    }

    /// Forwards the scale to every sublayer, so the gradients and brows render at the display's
    /// resolution.
    override var contentsScale: CGFloat {
        didSet {
            let lit = (leftLight + rightLight).flatMap { [$0, $0.mask].compactMap { $0 } }
            for layer in [body, silhouette, leftBrow, rightBrow, leftContact, rightContact] + (body.sublayers ?? []) + lit {
                layer.contentsScale = contentsScale
            }
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The body's outline in the body layer's coordinates, as it clips the body.
    var bodyOutline: CGPath? {
        silhouette.path
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        withoutActions {
            // A square around the sphere's centre, large enough for the shape.
            let outline = shape.outline
            let radius  = min(bounds.width, bounds.height) / 2
            let reach   = max(1, outline.extent)
            body.frame = CGRect(
                x     : bounds.midX - reach * radius,
                y     : bounds.midY - reach * radius,
                width : 2 * reach * radius,
                height: 2 * reach * radius
            )
            for layer in (body.sublayers ?? []) + [silhouette] {
                layer.frame = body.bounds
            }
            // The outline's y points down, the layer's up.
            silhouette.path = outline.path(transform: CGAffineTransform(
                translationX: reach * radius,
                y           : reach * radius
            ).scaledBy(
                x: radius,
                y: -radius
            ))
            placeGradients(
                reach : reach,
                bottom: outline.bottom
            )
            placeBrows()
        }
        scheduleBehaviourRefresh()
    }

    /// Places the gradients where they fall on the sphere's square, in a body `reach` times as
    /// large; the bounce follows the outline's lowest point, `bottom` sphere radii below the centre.
    private func placeGradients(
        reach : Double,
        bottom: Double
    ) {
        typealias Place = (gradient: CAGradientLayer, x: Double, top: Double, radiusX: Double, radiusY: Double)
        let places: [Place] = [
            (base,    0.37, 0.30,                   0.942, 0.942),
            (shading, 0.5,  0.25,                   0.85,  0.85),
            (bounce,  0.5,  1.1 + (bottom - 1) / 2, 1.0,   0.6),
            (sheen,   0.34, 0.26,                   0.42,  0.36),
        ]
        for place in places {
            Self.center(
                place.gradient,
                x      : 0.5 + (place.x - 0.5) / reach,
                top    : 0.5 + (place.top - 0.5) / reach,
                radiusX: place.radiusX / reach,
                radiusY: place.radiusY / reach
            )
        }
    }

    /// Shows `state`. Animated, each brow whose shape group changes morphs as `BrowTransition`
    /// says; under Reduce Motion, or not animated, the brows cut to the new outline.
    @MainActor
    func show(
        _ state : BrowState,
        animated: Bool
    ) {
        guard state != self.state else { return }
        let transition = BrowTransition.between(
            heldBrows,
            state,
            leftFirst: leftLeads
        )
        let animates = animated && !RestylingMotion.reducesMotion
        let now      = convertTime(CACurrentMediaTime(), from: nil)
        self.state = state
        heldBrows  = state
        if transition.movesLeft {
            morph(
                leftBrow,
                to      : BrowOutlines.bundled.left[state],
                duration: transition.duration,
                begin   : now + transition.leftDelay,
                animated: animates
            )
        }
        if transition.movesRight {
            morph(
                rightBrow,
                to      : BrowOutlines.bundled.right[state],
                duration: transition.duration,
                begin   : now + transition.rightDelay,
                animated: animates
            )
        }
        if animates { leftLeads.toggle() }
    }

    /// Turns the brows on the sphere toward the pointer, as the prototype's `side()` does: they
    /// shift and narrow toward the edge, and move up and down with `pitch`. `yaw` is -1...1, positive
    /// with the pointer to the right; `pitch` is -1...1, positive with the pointer below, which lifts
    /// the brows as the prototype does. An idle mascot looks right past a small dead zone, both brows
    /// together in 0.2 s.
    @MainActor
    func look(
        yaw  : Double,
        pitch: Double
    ) {
        self.yaw   = yaw
        self.pitch = pitch
        let animates = !RestylingMotion.reducesMotion
        if state == .idle {
            let wanted = yaw > 0.06 ? BrowState.look : (yaw < -0.06 ? BrowState.idle : heldBrows)
            if wanted != heldBrows {
                heldBrows = wanted
                let now = convertTime(CACurrentMediaTime(), from: nil)
                morph(
                    leftBrow,
                    to      : BrowOutlines.bundled.left[wanted],
                    duration: Self.lookSeconds,
                    begin   : now,
                    animated: animates
                )
                morph(
                    rightBrow,
                    to      : BrowOutlines.bundled.right[wanted],
                    duration: Self.lookSeconds,
                    begin   : now,
                    animated: animates
                )
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animates)
        CATransaction.setAnimationDuration(Self.lookSeconds)
        placeBrows()
        CATransaction.commit()
    }

    /// The loop the brows play in the current status, or nil while they hold still.
    private(set) var behaviour: WorkerBehaviourLoop?

    /// When `behaviour` started, or starts after the state change's blend, on the host clock.
    private(set) var behaviourStart: CFTimeInterval = 0

    /// Plays the loop `seed` gives in the current status (`WorkerBehaviour.seed(for:)` gives a
    /// worker's), or stops the brows' behaviour when `seed` is nil. Call it after `show(_:animated:)`
    /// and after every change of `status`; an unchanged seed and status keep the loop running.
    ///
    /// A new loop blends: each brow goes from where it shows now back to rest in the time and stagger
    /// of the state change, then the loop starts once the outline's morph is done. Under Reduce Motion
    /// the brows cut to rest and nothing plays. The shifts follow the face as the room shows it
    /// (`projectedFace`) and are rebuilt when it changes size (`refreshBehaviourScale()`).
    @MainActor
    func behave(seed: UInt64?) {
        let isUnchanged = seed == nil
            ? behaviour == nil
            : behaviour?.seed == seed && behaviour?.status == status
        guard !isUnchanged else { return }
        let previous = behaviour
        behaviour = seed.map { WorkerBehaviour(status).loop(seed: $0) }

        let animates   = !RestylingMotion.reducesMotion
        let host       = CACurrentMediaTime()
        let now        = convertTime(host, from: nil)
        let scale      = behaviourScale
        behaviourBuiltScale = scale
        let transition = BrowTransition.between(
            previous?.base ?? state,
            BrowState(status),
            leftFirst: leftLeads
        )
        let loopStart = now + transition.duration + max(transition.leftDelay, transition.rightDelay)
        behaviourStart = host + loopStart - now
        let sides: [(brow: CAShapeLayer, side: WorkerBehaviourLoop.Side, delay: Double)] = [
            (leftBrow, .left, transition.leftDelay),
            (rightBrow, .right, transition.rightDelay),
        ]
        for (brow, side, delay) in sides {
            let shown = brow.presentation()
            let shift = CGPoint(
                x: (shown?.position.x ?? brow.position.x) - brow.position.x,
                y: (shown?.position.y ?? brow.position.y) - brow.position.y
            )
            let turn = Self.rotation(of: shown ?? brow) - Self.rotation(of: brow)
            for key in Self.behaviourKeys {
                brow.removeAnimation(forKey: key)
            }
            for layer in outlineLayers(of: brow) {
                layer.removeAnimation(forKey: WorkerBehaviourLoop.pathKey)
            }
            guard animates else { continue }

            let blends: [(key: String, keyPath: String, from: Any)] = [
                (Self.blendPositionKey, "position", NSValue(point: shift)),
                (Self.blendRotationKey, "transform.rotation.z", turn),
            ]
            for (key, keyPath, from) in blends {
                let blend = CABasicAnimation(keyPath: keyPath)
                blend.fromValue      = from
                blend.toValue        = keyPath == "position" ? NSValue(point: .zero) : 0.0
                blend.isAdditive     = true
                blend.duration       = transition.duration
                blend.beginTime      = now + delay
                blend.fillMode       = .backwards
                blend.timingFunction = Self.morphCurve
                brow.add(
                    blend,
                    forKey: key
                )
            }
            guard let behaviour else { continue }
            let loop = behaviour.animations(
                for    : side,
                face   : faceSide,
                stretch: projectedStretch
            )
            for (key, animation) in loop {
                animation.beginTime = loopStart
                let layers = key == WorkerBehaviourLoop.pathKey ? outlineLayers(of: brow) : [brow]
                for layer in layers {
                    layer.add(
                        animation,
                        forKey: key
                    )
                }
            }
        }
    }

    /// The side of the face the brows sit on, in points: the sphere's, or the shape's inscribed circle.
    private var faceSide: CGFloat {
        min(bounds.width, bounds.height) * shape.outline.inradius
    }

    /// How much wider and taller than from above the room's camera shows the face; 1 from above.
    private var projectedStretch: CGSize {
        CGSize(
            width : projectedFace?.xScale ?? 1,
            height: projectedFace?.yScale ?? 1
        )
    }

    /// Points a loop shift of one face width moves the brows by, across and up, as the room shows them.
    private var behaviourScale: CGSize {
        CGSize(
            width : faceSide * projectedStretch.width,
            height: faceSide * projectedStretch.height
        )
    }

    /// The scale the running loop was built for.
    private var behaviourBuiltScale = CGSize.zero

    /// The pending end-of-resize rebuild.
    private var behaviourRefresh: DispatchWorkItem?

    /// How long the face holds one size before the loop's shifts are rebuilt for it.
    private static let refreshDelay = 0.15

    /// Asks for the running loop's shifts to be rebuilt once the face stops changing size: a resize,
    /// a compaction, a rows and grid change, or a new camera angle. One timer exists only while the
    /// size is moving; a settled face and a stopped loop start none.
    private func scheduleBehaviourRefresh() {
        behaviourRefresh?.cancel()
        behaviourRefresh = nil
        guard behaviour != nil, Self.differs(behaviourScale, behaviourBuiltScale) else { return }
        // The layer belongs to the main thread, where the item runs.
        nonisolated(unsafe) weak var layer = self
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { layer?.refreshBehaviourScale() }
        }
        behaviourRefresh = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.refreshDelay,
            execute : work
        )
    }

    private static func differs(
        _ first : CGSize,
        _ second: CGSize
    ) -> Bool {
        abs(first.width - second.width) > 0.005 * max(1, second.width)
            || abs(first.height - second.height) > 0.005 * max(1, second.height)
    }

    /// Rebuilds the running loop's position shifts for the face's present size, in step with the
    /// loop: the new animation keeps the old one's start, so each brow stays at the same point of the
    /// loop, and a short blend from where it shows now hides the change of scale. Waits while a
    /// status change's blend still runs. Nothing under Reduce Motion or without a loop.
    @MainActor
    func refreshBehaviourScale() {
        behaviourRefresh = nil
        guard let behaviour, !RestylingMotion.reducesMotion else { return }
        let scale = behaviourScale
        guard Self.differs(scale, behaviourBuiltScale) else { return }
        let built = behaviourBuiltScale
        guard leftBrow.animation(forKey: Self.blendPositionKey) == nil,
              rightBrow.animation(forKey: Self.blendPositionKey) == nil
        else {
            scheduleBehaviourRefresh()
            return
        }
        behaviourBuiltScale = scale
        let ratio = CGSize(
            width : built.width > 0 ? scale.width / built.width : 1,
            height: built.height > 0 ? scale.height / built.height : 1
        )
        for (brow, side) in [(leftBrow, WorkerBehaviourLoop.Side.left), (rightBrow, .right)] {
            guard let old = brow.animation(forKey: WorkerBehaviourLoop.positionKey),
                  let fresh = behaviour.animations(
                      for    : side,
                      face   : faceSide,
                      stretch: projectedStretch
                  )[WorkerBehaviourLoop.positionKey]
            else { continue }
            // The loop's shift now, which the new scale stretches in place.
            let shown = brow.presentation()?.position ?? brow.position
            let shift = CGPoint(
                x: shown.x - brow.position.x,
                y: shown.y - brow.position.y
            )
            fresh.beginTime = old.beginTime
            brow.add(
                fresh,
                forKey: WorkerBehaviourLoop.positionKey
            )
            let jump = CGPoint(
                x: shift.x * (1 - ratio.width),
                y: shift.y * (1 - ratio.height)
            )
            guard abs(jump.x) + abs(jump.y) > 0.01 else { continue }
            let blend = CABasicAnimation(keyPath: "position")
            blend.fromValue      = NSValue(point: jump)
            blend.toValue        = NSValue(point: .zero)
            blend.isAdditive     = true
            blend.duration       = Self.refreshBlend
            blend.timingFunction = Self.morphCurve
            brow.add(
                blend,
                forKey: Self.refreshBlendKey
            )
        }
    }

    private static let refreshBlend    = 0.25
    private static let refreshBlendKey = "behaviour.refresh"

    static let blendPositionKey = "behaviour.blend.position"
    static let blendRotationKey = "behaviour.blend.rotation"

    private static let behaviourKeys = [
        WorkerBehaviourLoop.positionKey,
        WorkerBehaviourLoop.rotationKey,
        blendPositionKey,
        blendRotationKey,
        refreshBlendKey,
    ]

    /// Moves the brows with the body a room draws beneath them (`RoomBodyMotion.browMotion()`): the
    /// layer's additive shift, turn and change of scale, by key, starting with the body's motion at
    /// `start` on the host clock, or nil to leave them on the body at rest. Nothing under Reduce Motion.
    @MainActor
    func followBody(
        _ motion  : [String: CAAnimation]?,
        from start: CFTimeInterval = 0
    ) {
        for key in RoomBodyMotion.browKeys {
            removeAnimation(forKey: key)
        }
        guard let motion, !RestylingMotion.reducesMotion else { return }
        for (key, animation) in motion {
            animation.beginTime = convertTime(start, from: nil)
            add(
                animation,
                forKey: key
            )
        }
    }

    /// The key of the brows' shift with the body.
    static let bodyKey = RoomBodyMotion.browKeys[0]

    /// Whether the worker is away in the chat: the brows are hidden, but while they pass out of the
    /// room with the body or back in (`followPassage(_:from:)`).
    var isAway = false {
        didSet {
            guard isAway != oldValue else { return }
            withoutActions { opacity = isAway ? 0 : 1 }
        }
    }

    /// Moves the brows with the body stepping out of its room or back in, from `start` on the host
    /// clock: leaving, they look toward the camera first; both ways they follow the face the camera
    /// shows and fade with the body. Under Reduce Motion they only fade. Nil removes the passage.
    @MainActor
    func followPassage(
        _ passage : RoomPassage?,
        from start: CFTimeInterval
    ) {
        for key in Self.passageKeys {
            removeAnimation(forKey: key)
            leftBrow.removeAnimation(forKey: key)
            rightBrow.removeAnimation(forKey: key)
        }
        guard let passage else { return }
        var parts: [(layer: CALayer, key: String, animation: CAAnimation)] = [
            (self, Self.passageKeys[0], passage.envelope()),
        ]
        if !RestylingMotion.reducesMotion, passage.poses.count > 1 {
            parts += [
                (self, Self.passageKeys[1], passage.browShift()),
                (self, Self.passageKeys[2], passage.browScale()),
            ]
            if passage.isLeaving {
                for (brow, side) in [(leftBrow, 1.0), (rightBrow, -1.0)] {
                    parts += look(
                        brow,
                        turn    : side * RoomPassage.look.rotation,
                        duration: passage.duration
                    )
                }
            }
        }
        for part in parts {
            part.animation.beginTime = part.layer.convertTime(start, from: nil)
            part.layer.add(
                part.animation,
                forKey: part.key
            )
        }
    }

    /// `brow` raised and turned by `turn` toward the camera over the passage's first share, then held.
    private func look(
        _ brow  : CAShapeLayer,
        turn    : Double,
        duration: Double
    ) -> [(layer: CALayer, key: String, animation: CAAnimation)] {
        let rise = RoomPassage.look.dy * faceSide * projectedStretch.height
        let keys: [(String, String, [Any])] = [
            (Self.passageKeys[3], "position", [NSValue(point: .zero), NSValue(point: CGPoint(x: 0, y: rise))]),
            (Self.passageKeys[4], "transform.rotation.z", [0.0, turn]),
        ]
        return keys.map { key, keyPath, values in
            let look = CAKeyframeAnimation(keyPath: keyPath)
            look.values          = values + [values[1]]
            look.keyTimes        = [0, NSNumber(value: RoomPassage.lookShare), 1]
            look.timingFunctions = [Self.morphCurve, CAMediaTimingFunction(name: .linear)]
            look.duration        = duration
            look.isAdditive      = true
            return (brow, key, look)
        }
    }

    private static let passageKeys = [
        "passage.fade",
        "passage.shift",
        "passage.scale",
        "passage.look.position",
        "passage.look.rotation",
    ]

    /// The turn `layer` shows about its z axis, in radians.
    private static func rotation(of layer: CALayer) -> Double {
        (layer.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
    }

    /// Starts the head's slow rise and fall, one breath every `RestylingTiming.headBreath`.
    /// Under Reduce Motion the head stays still. Call it once the layer has its size.
    @MainActor
    func startBreathing() {
        guard !RestylingMotion.reducesMotion else {
            removeAnimation(forKey: Self.breatheKey)
            return
        }
        let breathe = CABasicAnimation(keyPath: "transform.translation.y")
        breathe.fromValue      = 0
        breathe.toValue        = bounds.height * 0.0045
        breathe.duration       = RestylingTiming.headBreath / 2
        breathe.autoreverses   = true
        breathe.repeatCount    = .infinity
        breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.4, 1)
        add(breathe, forKey: Self.breatheKey)
    }

    /// Squashes and stretches the head once, as a worker setting about a task does: wide and low,
    /// then tall and a little up, over `RestylingTiming.preparation`. Added to the breath, which
    /// goes on. Nothing under Reduce Motion.
    @MainActor
    func prepare() {
        guard !RestylingMotion.reducesMotion else { return }

        let lift   = bounds.height * Self.preparationLift
        let keys   = Self.preparationKeys
        let curve  = CAMediaTimingFunction(name: .easeInEaseOut)
        let group  = CAAnimationGroup()
        group.animations = [
            ("transform.scale.x", keys.width),
            ("transform.scale.y", keys.height),
            ("transform.translation.y", keys.rise.map { $0 * lift }),
        ].map { keyPath, values in
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values          = values
            animation.keyTimes        = keys.times.map { NSNumber(value: $0) }
            animation.timingFunctions = [curve, curve, curve]
            animation.isAdditive      = true
            return animation
        }
        group.duration = RestylingTiming.preparation
        add(group, forKey: Self.prepareKey)
    }

    /// The closed outline `points` traces, in the 240 × 170 artboard with its y axis turned up.
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x, y: artboard.height - $0.y) })
        path.closeSubpath()
        return path
    }

    private static let artboard    = CGSize(width: 240, height: 170)
    private static let lookSeconds = 0.2
    private static let breatheKey  = "breathe"
    private static let prepareKey  = "prepare"

    /// How far the head rises at the top of its preparation, against its size: 4 points at 56.
    static let preparationLift: CGFloat = 4.0 / 56

    /// The preparation's keyframes at `times`, eased in and out between them: the head's change of
    /// width and of height, and its rise as a share of its `preparationLift`. `HouseWorkerPortrait`
    /// plays the same on the whole worker.
    static let preparationKeys = (
        times : [0, 0.35, 0.7, 1.0],
        width : [0, 0.14, -0.07, 0.0],
        height: [0, -0.14, 0.08, 0.0],
        rise  : [0, 0, 1, 0.0]
    )

    private static var morphCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
    }

    private func morph(
        _ brow   : CAShapeLayer,
        to points: [CGPoint]?,
        duration : Double,
        begin    : CFTimeInterval,
        animated : Bool
    ) {
        guard let points else { return }
        let target = Self.path(points)
        let start  = brow.presentation()?.path ?? brow.path
        let layers = outlineLayers(of: brow)
        withoutActions {
            for layer in layers {
                layer.path = target
            }
        }
        guard animated else {
            for layer in layers {
                layer.removeAnimation(forKey: "path")
            }
            return
        }
        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue      = start
        morph.toValue        = target
        morph.duration       = duration
        morph.beginTime      = begin
        morph.fillMode       = .backwards
        morph.timingFunction = Self.morphCurve
        for layer in layers {
            layer.add(morph, forKey: "path")
        }
    }

    /// Places the brows by the ibrows layout on the face, the shape's inscribed circle (the whole
    /// sphere for the circle): together they span 54% of its width, 9% of that is the gap, and their
    /// line sits 36% from its top; then turns them by `yaw` and `pitch`. In a tilted room they centre
    /// on `projectedFace` instead, stretched as the camera shows the face there.
    private func placeBrows() {
        let face      = min(bounds.width, bounds.height) * shape.outline.inradius
        let span      = face * 0.54
        let sideWidth = span * 0.455
        let scale     = sideWidth / Self.artboard.width
        let stretch   = (x: projectedFace?.xScale ?? 1, y: projectedFace?.yScale ?? 1)
        let anchor    = projectedFace.map { CGPoint(x: $0.anchor.dx, y: -$0.anchor.dy) }
            ?? CGPoint(x: 0, y: Self.browLift * face)
        let centerX   = bounds.midX + anchor.x + stretch.x * sin(yaw * 0.62) * 0.025 * face
        let centerY   = bounds.midY + anchor.y + stretch.y * sin(pitch * 0.30) * 0.17 * face
        for (brow, rest, side) in [(leftBrow, -0.42, -1.0), (rightBrow, 0.42, 1.0)] {
            let angle = rest + yaw * 0.62
            let depth = abs(cos(angle))
            let shift = (sin(angle) - sin(rest)) * 0.46 * sideWidth
            brow.position = CGPoint(
                x: centerX + stretch.x * side * (span - sideWidth) / 2 + stretch.x * shift,
                y: centerY
            )
            brow.transform = CATransform3DMakeScale(
                stretch.x * scale * max(0.12, depth),
                stretch.y * scale,
                1
            )
            brow.opacity = Float(0.35 + 0.65 * min(1, depth * 1.6))
            // The contact shadow sits a hair lower, so a thread of it shows under the brow.
            let contact = self.contact(of: brow)
            contact.position  = CGPoint(
                x: brow.position.x,
                y: brow.position.y - stretch.y * Self.contactDrop * face
            )
            contact.transform = brow.transform
            contact.opacity   = brow.opacity
        }
    }

    /// Lights the brows' top edge with the status light when `catches` is true, as the room's light
    /// above reaches them: up to `roomLightTint` of the light at the edge, fading to white within the
    /// brow, pulsing with the room's busy flicker or waiting breath in step with `RoomLightView`. A
    /// worker that is off, or not in a room, keeps plain brows; under Reduce Motion the light holds
    /// still. Call it after every change of `status`.
    @MainActor
    func catchRoomLight(_ catches: Bool) {
        let litLayers = [leftBrow, rightBrow] + leftLight + rightLight
        for layer in litLayers {
            layer.removeAnimation(forKey: Self.roomLightKey)
        }
        applyColors()
        guard catches, let light = status.light else { return }
        let strength = status.lightStrength
        // The top band and the middle one take the room's light at a weight of the pulse, over the
        // enamel's own tone; the shaded bottom keeps its tone.
        func fill(
            _ weight: Float,
            share   : Double,
            tone    : (red: Double, green: Double, blue: Double)
        ) -> CGColor {
            let amount = Self.roomLightTint * strength * Double(weight) * share
            return CGColor(
                srgbRed: tone.red * (1 - amount) + light.red * amount,
                green  : tone.green * (1 - amount) + light.green * amount,
                blue   : tone.blue * (1 - amount) + light.blue * amount,
                alpha  : 1
            )
        }
        let tones = Self.enamel
        let layers: [(layer: CAShapeLayer, share: Double, tone: (red: Double, green: Double, blue: Double))] =
            [leftBrow, rightBrow].map { ($0, 1, tones.top) }
            + [leftLight[0], rightLight[0]].map { ($0, 0.5, tones.middle) }
        withoutActions {
            for (layer, share, tone) in layers {
                layer.fillColor = fill(1, share: share, tone: tone)
            }
        }
        for (layer, share, tone) in layers {
            guard let pulse = RoomLightView.pulseFollowing(
                "fillColor",
                for  : status,
                in   : layer,
                value: { fill($0, share: share, tone: tone) }
            ) else { return }
            layer.add(
                pulse,
                forKey: Self.roomLightKey
            )
        }
    }

    /// The share of the room's light at the brows' top edge, at full strength.
    static let roomLightTint = 0.4

    /// The enamel's tones, sRGB, from its lit top band through the middle to its shaded bottom: white,
    /// or grey for a worker that is off.
    static let enamel    = (
        top   : (red: 0.98, green: 0.98, blue: 0.985),
        middle: (red: 0.95, green: 0.95, blue: 0.955),
        bottom: (red: 0.89, green: 0.89, blue: 0.9)
    )
    static let offEnamel = (
        top   : (red: 0.52, green: 0.53, blue: 0.56),
        middle: (red: 0.48, green: 0.49, blue: 0.52),
        bottom: (red: 0.42, green: 0.43, blue: 0.46)
    )

    /// The contact shadow's darkness, and how far below the brow it sits, as a share of the face.
    static let contactOpacity     = 0.5
    static let contactDrop: Double = 0.012

    static let roomLightKey = "roomLight"

    /// How deep the lit edge reaches into a brow, in the 240 × 170 artboard.
    private static let litEdge: CGFloat = 46

    /// The layers that keep `brow` white below its lit edge, nearest the edge first.
    func lightCopies(of brow: CAShapeLayer) -> [CAShapeLayer] {
        brow === leftBrow ? leftLight : rightLight
    }

    /// The enamel's own tones on the brows and their copies, and the dimming of a worker that is off.
    private func applyColors() {
        let isOff = status == .off
        let tones = isOff ? Self.offEnamel : Self.enamel
        func color(_ tone: (red: Double, green: Double, blue: Double)) -> CGColor {
            CGColor(
                srgbRed: tone.red,
                green  : tone.green,
                blue   : tone.blue,
                alpha  : 1
            )
        }
        withoutActions {
            dimming.opacity = isOff ? 0.55 : 0
            for brow in [leftBrow, rightBrow] {
                brow.fillColor = color(tones.top)
                let copies = lightCopies(of: brow)
                copies[0].fillColor = color(tones.middle)
                copies[1].fillColor = color(tones.bottom)
                for copy in copies {
                    copy.isHidden = false
                }
            }
        }
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    private static func color(hex: Int) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green  : CGFloat((hex >> 8) & 0xFF) / 255,
            blue   : CGFloat(hex & 0xFF) / 255,
            alpha  : 1
        )
    }

    /// Centres a radial gradient at `x`, `top` (a fraction from the top edge, as CSS measures it)
    /// with the given radii, all in the layer's unit space.
    private static func center(
        _ gradient: CAGradientLayer,
        x         : Double,
        top       : Double,
        radiusX   : Double,
        radiusY   : Double
    ) {
        gradient.startPoint = CGPoint(
            x: x,
            y: 1 - top
        )
        gradient.endPoint = CGPoint(
            x: x + radiusX,
            y: 1 - top + radiusY
        )
    }
}
