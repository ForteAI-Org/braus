//
//  HouseAwayPlaque.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// HouseAwayPlaque is the sign hanging in an empty room while its worker is in the chat: a small
/// slab of thick frosted glass, with the worker's brows and "In chat with you" etched into it.
///
/// Every room has one, laid over the whole room and hidden while the worker is there, so selecting
/// the worker only shows it and starts its swing, on layers that already exist; a plaque made for a
/// room that is already empty, as when the sidebar is rebuilt, hangs still. It is part of the room's
/// accessibility label, so it is hidden from VoiceOver itself.
struct HouseAwayPlaque: NSViewRepresentable {
    let brows    : BrowState
    let status   : WorkerStatus
    let isHanging: Bool
    var camera   = RoomCamera.top
    var lean     = Float(0)

    /// How long the plaque waits to drop in once its worker is chosen: while the worker steps out.
    var dropDelay: TimeInterval = 0

    /// What the plate says, and what the room's accessibility label adds.
    static let text = "In chat with you"

    func makeNSView(context: Context) -> PlaqueView {
        PlaqueView(
            brows    : brows,
            status   : status,
            isHanging: isHanging,
            camera   : camera,
            lean     : lean,
            dropDelay: dropDelay
        )
    }

    func updateNSView(
        _ view : PlaqueView,
        context: Context
    ) {
        view.brows     = brows
        view.status    = status
        view.camera    = camera
        view.lean      = lean
        view.dropDelay = dropDelay
        view.isHanging = isHanging
    }

    /// PlaqueView draws the plaque over its room and moves it with Core Animation only.
    ///
    /// - The drop-in: when `isHanging` turns true, after `dropDelay`, a spring on the plate's rotation
    ///   about its pivot that settles in about a second; under Reduce Motion a fade. Taken down, it
    ///   fades over `RestylingTiming.plaqueLeave`.
    /// - The pendulum: while the room moves sideways the plate hangs on the same spring from its
    ///   pivot. A change of the pivot's speed throws it the other way and the speed leans it back, so
    ///   a room setting off to the left leaves the plate's foot to the right, and a room stopping
    ///   swings it on past rest; it never turns past `maximumTilt`. The pivot's position is read when
    ///   the room's layout moves it, so nothing runs at rest. Under Reduce Motion it never tilts.
    /// - The place and the size (`Metrics`): from above, the plate hangs from a nail over the worker's
    ///   place. Through the tilted camera it hangs in the room where the worker stood, from two cords
    ///   rising out of the opening, seen in the room's perspective with its top face showing and its
    ///   shadow on the floor; its pivot is where the cords leave the opening. The plate follows the
    ///   room's short side, as the sphere does, and never takes more than 70% of the room's width;
    ///   the text stays 9 points and is left out where it cannot fit. In a room leaning left it hangs
    ///   where the worker stood, at the left, within the worker's place beside the name.
    /// - The glass: the room behind shows through it blurred and tinted, by the system's material
    ///   (`NSVisualEffectView` blending within the window, which takes the room's Metal layer behind
    ///   it as it is, pulse and all) seen only through a mask that turns with the plate, under the
    ///   glass's smoky tone; the marks are etched lighter into it. Under Reduce Transparency nothing
    ///   shows through: the plate is an opaque frosted tone.
    /// - The light: the lamp's light enters the glass through its top face, which glows; the light
    ///   refracted down from there fades through the slab, its edge glows brightest at the top, and
    ///   the lamp's reflection slides as the plate turns. All of it pulses with the room on the host
    ///   clock. The plate's soft shadow is tinted where the light passes through the glass. None of
    ///   the light in the room of a worker that is off. The ray-traced path will cast the coloured
    ///   shadow itself with the lights; until then it is Core Animation's on both paths.
    final class PlaqueView: NSView {

        /// The worker's expression, etched small into the plate.
        var brows: BrowState {
            didSet {
                guard brows != oldValue else { return }
                drawBrows()
            }
        }

        /// The room's status, whose light falls on the plate.
        var status: WorkerStatus {
            didSet {
                guard status != oldValue else { return }
                applyLight()
            }
        }

        /// How the room is seen, which decides where the plaque hangs.
        var camera: RoomCamera {
            didSet {
                guard camera != oldValue else { return }
                needsLayout = true
            }
        }

        /// How far the room's composition leans left, which moves the plaque with the worker's place.
        var lean: Float {
            didSet {
                guard lean != oldValue else { return }
                needsLayout = true
            }
        }

        /// Whether the plaque hangs in the room; turning true drops it in after `dropDelay`.
        var isHanging: Bool {
            didSet {
                guard isHanging != oldValue else { return }
                if isHanging {
                    drop()
                } else {
                    takeDown()
                }
            }
        }

        /// How long the plaque waits to drop in once it hangs: while its worker steps out of the room.
        var dropDelay: TimeInterval

        /// The drop-in waiting for `dropDelay`, while it waits.
        private(set) var dropTask: Task<Void, Never>?

        /// The rotation about the pivot, and with it the cords and the slab.
        let swingLayer = CALayer()

        /// The plate's shadow, turning with it.
        let shadowLayer = CALayer()

        /// The slab's face, clipped to the plate's rounded shape and seen in the room's perspective.
        let glassLayer = CALayer()

        /// The room behind the slab, blurred by the system's material and seen through a mask that
        /// turns with the plate; hidden under Reduce Transparency and while the plaque is down.
        let frostView = NSView()

        /// The room's light in the glass, pulsing with the room.
        let lightLayer = CALayer()

        /// The light passing through the glass that tints its shadow, pulsing with the room.
        let castLayer = CALayer()

        /// The slab's top face, which shows through the tilted camera and glows where the lamp's light
        /// enters, pulsing with the room.
        let rimLayer = CAShapeLayer()

        /// "In chat with you" etched into the face, as the glyphs' outlines: a shape is drawn at the
        /// screen's resolution through the room's perspective, where a text layer's bitmap would be
        /// resampled and soften by how its pixels happen to fall.
        let textLayer = CAShapeLayer()

        static let swingKey = "swing"
        static let fadeKey  = "fade"
        static let pulseKey = "pulse"

        /// The plate's turn at its widest, in radians, either way.
        static let maximumTilt = 7 * Double.pi / 180

        /// The share of `maximumTilt` the plate leans at most behind a pivot moving steadily.
        static let maximumLean = 0.3

        /// The pivot's speed, in points per second, that leans the plate fully.
        static let fullLeanSpeed = 240.0

        /// How much the plate's turning speed, in radians per second, changes against each point per
        /// second the pivot's speed changes: a pivot that sets off pushes the plate back, one that
        /// stops throws it forward.
        static let inertia = 0.005

        /// The etched marks' colour: the design's off-white, frosted.
        private static let ink = CGColor(
            srgbRed: 245.0 / 255,
            green  : 245.0 / 255,
            blue   : 247.0 / 255,
            alpha  : 0.9
        )

        /// The glass's own smoky tone over the blurred room, top and bottom, and the opaque frosted
        /// tone it becomes under Reduce Transparency, about what the glass shows over a lit room.
        private static let tone = (
            top   : CGColor(
                gray : 0.3,
                alpha: 0.42
            ),
            bottom: CGColor(
                gray : 0.2,
                alpha: 0.5
            )
        )
        private static let opaqueTone = (
            top   : CGColor(
                gray : 0.21,
                alpha: 1
            ),
            bottom: CGColor(
                gray : 0.15,
                alpha: 1
            )
        )

        /// The material the room is blurred through.
        private static let material = NSVisualEffectView.Material.hudWindow

        static let font = NSFont.systemFont(
            ofSize: 9,
            weight: .medium
        )

        /// The pause in the pivot's movement that counts as a stop.
        private static let stopPause = Duration.milliseconds(60)

        /// How far the plate starts turned when it drops in, in radians.
        private static let dropAngle = 0.32

        private static let fadeSeconds = 0.2

        /// How deep the etched marks are cut, as the height of the shade above them, in points.
        private static let etchDepth: CGFloat = 0.5

        private let effectView = NSVisualEffectView()
        private let frostMask  = CALayer()
        private let faceMask   = CAShapeLayer()
        private let rimMask    = CAShapeLayer()
        private let cords      = CAShapeLayer()
        private let nail       = CALayer()
        private let wallShadow = CALayer()
        private let body       = CAGradientLayer()
        private let refraction = CAGradientLayer()
        private let edge       = CAShapeLayer()
        private let edgeFade   = CAGradientLayer()
        private let sheen      = CAGradientLayer()
        private let leftBrow   = CAShapeLayer()
        private let rightBrow  = CAShapeLayer()

        /// The layers that turn together about the pivot: the slab, its shadow and the frost's mask.
        private var turningLayers: [CALayer] {
            [swingLayer, shadowLayer, frostMask]
        }

        /// The plate's turn in the model, where every animation ends.
        private var angle = 0.0

        /// The plate's width, which the sheen travels a share of.
        private var plateWidth: CGFloat = 0

        /// Whether the text was shown at the last layout, so that a change fades.
        private var showsText: Bool?

        /// The spring the plate is on, from which its angle and speed at any moment follow; nil
        /// at rest.
        private(set) var swing: Swing?

        /// The pivot's last position in the window and when it was read, and its speed.
        private var anchor        : (x: CGFloat, time: CFTimeInterval)?
        private var anchorVelocity = 0.0
        private var stopTask      : Task<Void, Never>?

        init(
            brows    : BrowState,
            status   : WorkerStatus,
            isHanging: Bool,
            camera   : RoomCamera = .top,
            lean     : Float = 0,
            dropDelay: TimeInterval = 0
        ) {
            self.brows     = brows
            self.status    = status
            self.camera    = camera
            self.lean      = lean
            self.isHanging = isHanging
            self.dropDelay = dropDelay
            super.init(frame: .zero)
            wantsLayer = true
            build()
            drawBrows()
            withoutActions { setShown(isHanging) }
            applyMaterial()
            applyLight()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            anchor = nil
            observeHost()
            guard window != nil else { return }
            updateContentsScale()
            // A pulse phased to the host clock needs the layer in a window.
            applyLight()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateContentsScale()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeHost()
        }

        /// Follows the frame of the view hosting this one while both are in a window: SwiftUI moves a
        /// room, its springs included, by moving that view. The observation is a selector's, which
        /// the notification center also drops when this view goes away.
        private func observeHost() {
            NotificationCenter.default.removeObserver(
                self,
                name  : NSView.frameDidChangeNotification,
                object: nil
            )
            guard window != nil, let superview else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostMoved),
                name    : NSView.frameDidChangeNotification,
                object  : superview
            )
        }

        @objc private func hostMoved(_ notification: Notification) {
            followAnchor()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // A hidden plaque is placed when it is shown, so the rooms that are occupied cost nothing.
            guard isHanging else { return }
            arrange()
            followAnchor()
        }

        /// Places the plaque for the room's size, fading the text in or out when that changes.
        private func arrange() {
            let metrics  = Metrics(
                room  : bounds.size,
                camera: camera,
                lean  : lean
            )
            let animates = showsText != nil && showsText != metrics.showsText && !RestylingMotion.reducesMotion
            showsText = metrics.showsText
            CATransaction.begin()
            CATransaction.setDisableActions(!animates)
            CATransaction.setAnimationDuration(0.15)
            place(metrics)
            CATransaction.commit()
        }

        // MARK: Swing

        /// Brings the plaque down once `dropDelay` has passed, at once without one.
        private func drop() {
            dropTask?.cancel()
            dropTask = nil
            guard dropDelay > 0 else {
                hang()
                return
            }
            let delay = dropDelay
            dropTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self, self.isHanging else { return }
                self.dropTask = nil
                self.hang()
            }
        }

        /// Brings the plaque down: a swing that settles at rest, or a fade under Reduce Motion.
        func hang() {
            stopTask?.cancel()
            anchor         = nil
            anchorVelocity = 0
            showsText      = nil
            arrange()
            applyMaterial()
            applyLight()
            withoutActions { setShown(true) }
            for layer in fadingLayers {
                layer.removeAnimation(forKey: Self.fadeKey)
            }
            guard !RestylingMotion.reducesMotion else {
                rest()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue   = 1
                fade.duration  = Self.fadeSeconds
                for layer in fadingLayers {
                    layer.add(
                        fade,
                        forKey: Self.fadeKey
                    )
                }
                return
            }
            play(Swing(
                from    : Self.dropAngle,
                velocity: 0,
                target  : 0,
                start   : CACurrentMediaTime()
            ))
        }

        /// The plate's lean, in radians, behind a pivot moving sideways at `velocity` points per
        /// second: a pivot moving left turns it counterclockwise, which keeps its foot to the right
        /// (the view's layer has its y axis up). At most `maximumLean` of `maximumTilt`; zero under
        /// Reduce Motion.
        static func tilt(
            forAnchorVelocity velocity: Double,
            reducesMotion             : Bool
        ) -> Double {
            guard !reducesMotion else { return 0 }
            let lean = maximumLean * maximumTilt
            return min(
                lean,
                max(
                    -lean,
                    -velocity / fullLeanSpeed * lean
                )
            )
        }

        /// Reads the pivot's position in the window, once the layout has moved the room.
        func followAnchor() {
            guard window != nil else { return }
            nailMoved(
                to: convert(
                    NSPoint(
                        x: bounds.midX,
                        y: 0
                    ),
                    to: nil
                ).x,
                at: CACurrentMediaTime()
            )
        }

        /// Moves the plate after its pivot, now at `x` points in the window at `time`: a change of
        /// the pivot's speed throws the plate the other way (`inertia`) and its speed leans the plate
        /// back, within `maximumTilt`. Once the pivot pauses for `stopPause`, it has stopped: the plate
        /// swings on the way the pivot went, past rest, and settles. Nothing under Reduce Motion.
        func nailMoved(
            to x   : CGFloat,
            at time: CFTimeInterval
        ) {
            guard isHanging, !RestylingMotion.reducesMotion else { return }
            guard let last = anchor else {
                anchor = (x, time)
                return
            }
            // Two layout passes in one frame would read as an absurd speed; the later one waits.
            guard time - last.time >= 0.004 else { return }
            anchor = (x, time)
            guard abs(x - last.x) > 0.01 else { return }
            let velocity = 0.6 * Double(x - last.x) / (time - last.time) + 0.4 * anchorVelocity
            turn(
                toward : Self.tilt(
                    forAnchorVelocity: velocity,
                    reducesMotion    : false
                ),
                kicked : velocity - anchorVelocity,
                at     : time
            )
            anchorVelocity = velocity
            stopTask?.cancel()
            stopTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.stopPause)
                } catch {
                    return
                }
                self?.nailStopped(at: CACurrentMediaTime())
            }
        }

        /// The pivot has stopped at `time`: its speed drops to zero at once, which throws the plate
        /// on the way the pivot went, and the plate swings back to rest.
        func nailStopped(at time: CFTimeInterval) {
            guard isHanging, !RestylingMotion.reducesMotion else { return }
            stopTask?.cancel()
            stopTask = nil
            anchor   = nil
            turn(
                toward: 0,
                kicked: -anchorVelocity,
                at    : time
            )
            anchorVelocity = 0
        }

        /// Puts the plate on a new spring toward `target` from where it is at `time`, its turning
        /// speed changed against `kicked`, the pivot's change of speed. The speed is cut so that no
        /// swing about `target` reaches past `maximumTilt`.
        private func turn(
            toward target: Double,
            kicked       : Double,
            at time      : CFTimeInterval
        ) {
            let now      = swing?.state(at: time) ?? (angle: angle, velocity: 0)
            var from     = min(Self.maximumTilt, max(-Self.maximumTilt, now.angle))
            var velocity = now.velocity - Self.inertia * kicked
            let reach    = Self.maximumTilt - abs(target)
            let offset   = from - target
            // An undamped swing from here would reach this far from the target; a damped one less.
            if offset * offset + pow(velocity / Swing.frequency, 2) > reach * reach {
                let allowed = max(0, reach * reach - offset * offset).squareRoot()
                velocity = (velocity < 0 ? -1 : 1) * Swing.frequency * allowed
            }
            // Core Animation counts the speed in distances to the target, so a swing with speed starts
            // a hair behind its target rather than on it, where the speed would be lost.
            if from == target, velocity != 0 {
                from = target - (velocity < 0 ? -1 : 1) * Swing.leeway
            }
            play(Swing(
                from    : from,
                velocity: velocity,
                target  : target,
                start   : time
            ))
        }

        /// Animates the turn of the slab, its shadow and the frost's mask, and the sheen with them,
        /// along `next`.
        private func play(_ next: Swing) {
            swing = next
            set(angle: next.target)
            let turns = turningLayers.map { ($0, "transform.rotation.z", next.from, next.target) }
            for (layer, keyPath, from, to) in turns + [
                (sheen as CALayer, "position.x", sheenX(for: next.from), sheenX(for: next.target)),
            ] {
                let spring = CASpringAnimation(keyPath: keyPath)
                spring.fromValue = from
                spring.toValue   = to
                spring.mass      = 1
                spring.stiffness = Swing.stiffness
                spring.damping   = Swing.damping
                spring.initialVelocity = next.relativeVelocity
                spring.duration        = spring.settlingDuration
                layer.add(
                    spring,
                    forKey: Self.swingKey
                )
            }
        }

        /// Stops the plate at rest, with no animation.
        private func rest() {
            swing = nil
            for layer in turningLayers + [sheen] {
                layer.removeAnimation(forKey: Self.swingKey)
            }
            set(angle: 0)
        }

        private func set(angle: Double) {
            self.angle = angle
            withoutActions {
                for layer in turningLayers {
                    layer.setValue(
                        angle,
                        forKeyPath: "transform.rotation.z"
                    )
                }
                sheen.position.x = sheenX(for: angle)
            }
        }

        /// Where the sheen sits on the plate turned by `angle`: the lamp stays put while the plate
        /// turns under it, so the sheen slides against the turn, a fifth of the plate at full tilt.
        private func sheenX(for angle: Double) -> Double {
            Double(plateWidth) * (0.5 - 0.2 * angle / Self.maximumTilt)
        }

        /// Takes the plaque away: it fades over `RestylingTiming.plaqueLeave` and hides, so its worker
        /// steps back in after it; a plaque still waiting to drop in never shows.
        private func takeDown() {
            dropTask?.cancel()
            dropTask       = nil
            stopTask?.cancel()
            stopTask       = nil
            anchor         = nil
            anchorVelocity = 0
            let isShown = !swingLayer.isHidden
            withoutActions {
                for layer in fadingLayers {
                    layer.removeAllAnimations()
                }
                for layer in [lightLayer, castLayer, rimLayer] {
                    layer.removeAnimation(forKey: Self.pulseKey)
                }
                if !isShown { setShown(false) }
            }
            rest()
            guard isShown else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue             = 1
            fade.toValue               = 0
            fade.duration              = RestylingTiming.plaqueLeave
            fade.fillMode              = .forwards
            fade.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    // A plaque hung again meanwhile keeps showing.
                    guard let self, !self.isHanging else { return }
                    self.withoutActions {
                        for layer in self.fadingLayers {
                            layer.removeAnimation(forKey: Self.fadeKey)
                        }
                        self.setShown(false)
                    }
                }
            }
            for layer in fadingLayers {
                layer.add(
                    fade,
                    forKey: Self.fadeKey
                )
            }
            CATransaction.commit()
        }

        /// The layers that appear and fade together: the slab, its shadow and the frost.
        private var fadingLayers: [CALayer] {
            [swingLayer, shadowLayer] + (frostView.layer.map { [$0] } ?? [])
        }

        /// Shows or hides the plaque; the frost shows only where the room may show through the glass.
        private func setShown(_ isShown: Bool) {
            swingLayer.isHidden  = !isShown
            shadowLayer.isHidden = !isShown
            frostView.isHidden   = !isShown || RestylingMotion.reducesTransparency
        }

        /// Swing is one spring of the plate's rotation: from an angle and a turning speed toward a
        /// target, from a moment on, with the plaque's stiffness and damping. It gives the angle and
        /// the speed at any later moment as Core Animation plays the same spring.
        struct Swing {
            let from    : Double
            let velocity: Double
            let target  : Double
            let start   : CFTimeInterval

            /// A gentle swing that settles in about a second.
            static let stiffness = 120.0
            static let damping   = 9.0

            /// The undamped angular frequency, in radians per second, for a mass of 1.
            static let frequency = stiffness.squareRoot()

            /// How far behind its target a swing with speed starts when it would start on it, in radians.
            static let leeway = 1e-4

            /// The starting speed as Core Animation counts it: distances to the target per second,
            /// positive toward it. Zero for a swing that starts on its target, which only one at rest
            /// does: a swing with speed starts `leeway` behind.
            var relativeVelocity: Double {
                target == from ? 0 : velocity / (target - from)
            }

            /// The angle and the turning speed at `time`.
            func state(at time: CFTimeInterval) -> (angle: Double, velocity: Double) {
                let t      = max(0, time - start)
                let ratio  = Self.damping / (2 * Self.frequency)
                let decay  = ratio * Self.frequency
                let damped = Self.frequency * (1 - ratio * ratio).squareRoot()
                let offset = from - target
                let b      = (velocity + decay * offset) / damped
                let fade   = exp(-decay * t)
                let cosine = cos(damped * t)
                let sine   = sin(damped * t)
                return (
                    angle   : target + fade * (offset * cosine + b * sine),
                    velocity: fade * ((b * damped - decay * offset) * cosine - (offset * damped + decay * b) * sine)
                )
            }
        }

        // MARK: Light

        /// Lights the glass with the room's light and tints its shadow, pulsing with the room while the
        /// plaque hangs in a window, or leaves it unlit, with no shadow, when the worker is off.
        private func applyLight() {
            for layer in [lightLayer, castLayer, rimLayer] {
                layer.removeAnimation(forKey: Self.pulseKey)
            }
            guard let light = status.light else {
                withoutActions {
                    lightLayer.isHidden      = true
                    castLayer.isHidden       = true
                    wallShadow.shadowOpacity = 0
                    // Unlit, the top face still shows the glass's thickness.
                    rimLayer.fillColor = CGColor(
                        gray : 1,
                        alpha: 0.14
                    )
                }
                return
            }
            let strength = status.lightStrength
            // The light's colour toward white by `white`, at `share` of its strength.
            func color(
                _ share: Double,
                white  : Double = 0
            ) -> CGColor {
                CGColor(
                    srgbRed: light.red + (1 - light.red) * white,
                    green  : light.green + (1 - light.green) * white,
                    blue   : light.blue + (1 - light.blue) * white,
                    alpha  : share * strength
                )
            }
            withoutActions {
                lightLayer.isHidden = false
                castLayer.isHidden  = false
                refraction.colors   = [color(0.34), color(0.1), color(0), color(0.06)]
                edge.strokeColor    = color(
                    0.95,
                    white: 0.5
                )
                rimLayer.fillColor  = color(
                    0.8,
                    white: 0.55
                )
                sheen.colors = [
                    color(
                        0.2,
                        white: 0.6
                    ),
                    color(
                        0,
                        white: 0.6
                    ),
                ]
                // The shadow darkens toward the light's colour, and the light through the glass tints it.
                wallShadow.shadowColor   = CGColor(
                    srgbRed: 0.2 * light.red,
                    green  : 0.2 * light.green,
                    blue   : 0.2 * light.blue,
                    alpha  : 1
                )
                wallShadow.shadowOpacity = Float(0.55 * strength)
                castLayer.shadowColor    = CGColor(
                    srgbRed: light.red,
                    green  : light.green,
                    blue   : light.blue,
                    alpha  : 1
                )
                castLayer.shadowOpacity  = Float(0.5 * strength)
            }
            // Only a hanging plaque pulses; the hidden ones in occupied rooms cost nothing.
            guard isHanging, window != nil else { return }
            for layer in [lightLayer, castLayer, rimLayer] {
                guard let pulse = RoomLightView.pulseFollowing(
                    "opacity",
                    for  : status,
                    in   : layer,
                    value: { NSNumber(value: $0) }
                ) else { return }
                layer.add(
                    pulse,
                    forKey: Self.pulseKey
                )
            }
        }

        /// Shows the room through the glass, or under Reduce Transparency makes the glass an opaque
        /// frosted tone with nothing behind it showing through.
        private func applyMaterial() {
            let isOpaque = RestylingMotion.reducesTransparency
            let tone     = isOpaque ? Self.opaqueTone : Self.tone
            withoutActions {
                frostView.isHidden = isOpaque || !isHanging
                body.colors        = [tone.top, tone.bottom]
            }
        }

        // MARK: Drawing

        private func place(_ metrics: Metrics) {
            let scale  = metrics.scale
            let plate  = metrics.plate
            let height = bounds.height
            // The metrics count y down; the view's layers count it up.
            func up(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: point.x,
                    y: height - point.y
                )
            }
            func path(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points.map(up))
                path.closeSubpath()
                return path
            }
            plateWidth = plate.width

            // Everything that turns covers the room and turns about the pivot.
            let pivot = up(CGPoint(
                x: metrics.nailX,
                y: metrics.top
            ))
            for layer in turningLayers {
                layer.bounds      = bounds
                layer.anchorPoint = CGPoint(
                    x: bounds.width > 0 ? pivot.x / bounds.width : 0.5,
                    y: height > 0 ? pivot.y / height : 1
                )
                layer.position    = pivot
            }
            frostView.frame = bounds
            if frostView.layer?.mask !== frostMask { frostView.layer?.mask = frostMask }

            nail.isHidden = camera == .tilted
            nail.frame    = CGRect(
                x     : pivot.x - 1.5 * scale,
                y     : pivot.y - 3 * scale,
                width : 3 * scale,
                height: 3 * scale
            )
            nail.cornerRadius = 1.5 * scale
            let strands = CGMutablePath()
            for cord in metrics.cords {
                strands.addLines(between: cord.map(up))
            }
            cords.path = strands

            // A given path spares Core Animation from tracing each shadow every frame.
            for (layer, outline, blur) in [
                (wallShadow, metrics.shadow, metrics.shadowBlur),
                (castLayer, metrics.cast, metrics.castBlur),
            ] {
                layer.frame        = bounds
                layer.shadowPath   = path(outline)
                layer.shadowRadius = blur
                layer.shadowOffset = .zero
            }

            // A rounded rectangle's corners may take at most half its sides.
            let corner     = min(
                Metrics.cornerRadius * scale,
                plate.width / 2,
                plate.height / 2
            )
            let plateFrame = CGRect(
                origin: .zero,
                size  : plate
            )
            let transform  = Metrics.transform(
                mapping: plate,
                to     : metrics.face.map(up)
            )
            for layer in [glassLayer, faceMask] as [CALayer] {
                layer.anchorPoint = .zero
                layer.bounds      = plateFrame
                layer.position    = .zero
                layer.transform   = transform
            }
            glassLayer.cornerRadius = corner
            faceMask.path           = CGPath(
                roundedRect : plateFrame,
                cornerWidth : corner,
                cornerHeight: corner,
                transform   : nil
            )
            let rim = metrics.rim.map(path)
            rimLayer.path = rim
            rimMask.path  = rim
            for layer in [body, lightLayer, refraction, edgeFade] as [CALayer] {
                layer.frame = plateFrame
            }
            edge.frame     = plateFrame
            edge.lineWidth = max(0.75, scale)
            let inner      = plateFrame.insetBy(
                dx: edge.lineWidth / 2,
                dy: edge.lineWidth / 2
            )
            let innerCorner = max(
                0,
                min(
                    corner - edge.lineWidth / 2,
                    inner.width / 2,
                    inner.height / 2
                )
            )
            edge.path = inner.isEmpty ? nil : CGPath(
                roundedRect : inner,
                cornerWidth : innerCorner,
                cornerHeight: innerCorner,
                transform   : nil
            )
            // The lamp's reflection keeps to the plate's upper part, above the text, which stays legible.
            sheen.bounds = CGRect(
                x     : 0,
                y     : 0,
                width : plate.width * 0.9,
                height: plate.height * 0.45
            )
            sheen.position = CGPoint(
                x: sheenX(for: angle),
                y: plate.height * 0.775
            )

            // The text's baseline sits where a 12-point line from `textBottom` puts it, centred across.
            let textBottom = max(2, 0.17 * plate.height)
            let lineTop    = textBottom + 12
            textLayer.frame = CGRect(
                x     : (plate.width - Metrics.textWidth) / 2,
                y     : lineTop - Self.font.ascender,
                width : Metrics.textWidth,
                height: Self.font.ascender
            )
            textLayer.opacity = metrics.showsText ? 1 : 0

            let span      = 22 * scale
            let sideWidth = span * 0.455
            let browScale = sideWidth / 240
            // The brows are centred in the space above the text's capitals, or on the plate without text.
            let capTop = lineTop - Self.font.ascender + Self.font.capHeight
            let browY  = metrics.showsText ? (capTop + plate.height) / 2 : plate.height / 2
            for (brow, side) in [
                (leftBrow, -1.0),
                (rightBrow, 1.0),
            ] {
                brow.position = CGPoint(
                    x: plate.width / 2 + side * (span - sideWidth) / 2,
                    y: browY
                )
                brow.transform = CATransform3DMakeScale(
                    browScale,
                    browScale,
                    1
                )
                // A brow's shade is offset in its own, scaled, coordinates.
                brow.shadowOffset = CGSize(
                    width : 0,
                    height: Self.etchDepth / browScale
                )
            }
        }

        private func build() {
            // The cords leave through the opening's top edge, which cuts them off.
            layer?.masksToBounds = true
            nail.backgroundColor = CGColor(
                gray : 0.62,
                alpha: 1
            )
            cords.fillColor   = nil
            cords.strokeColor = CGColor(
                gray : 0.5,
                alpha: 0.9
            )
            cords.lineWidth = 0.75

            glassLayer.cornerCurve   = .continuous
            glassLayer.masksToBounds = true
            // The slab's own rim, which shows in every light and in none.
            glassLayer.borderWidth = 0.5
            glassLayer.borderColor = CGColor(
                gray : 1,
                alpha: 0.14
            )
            body.startPoint = CGPoint(
                x: 0.5,
                y: 1
            )
            body.endPoint   = CGPoint(
                x: 0.5,
                y: 0
            )

            // The lamp is above the plate, so the light enters through the top and fades down through
            // the slab, a little of it reflected back up from the bottom edge.
            refraction.locations  = [0, 0.22, 0.6, 1]
            refraction.startPoint = body.startPoint
            refraction.endPoint   = body.endPoint
            edge.fillColor  = nil
            edgeFade.colors = [
                CGColor(
                    gray : 1,
                    alpha: 1
                ),
                CGColor(
                    gray : 1,
                    alpha: 0.35
                ),
                CGColor(
                    gray : 1,
                    alpha: 0.12
                ),
            ]
            edgeFade.locations  = [0, 0.3, 1]
            edgeFade.startPoint = body.startPoint
            edgeFade.endPoint   = body.endPoint
            edge.mask           = edgeFade
            // The lamp's reflection is a soft oval, with no edge for the glass to show.
            sheen.type       = .radial
            sheen.startPoint = CGPoint(
                x: 0.5,
                y: 0.5
            )
            sheen.endPoint   = CGPoint(
                x: 1,
                y: 1
            )
            for layer in [refraction, sheen, edge] as [CALayer] {
                lightLayer.addSublayer(layer)
            }

            for brow in [leftBrow, rightBrow] {
                brow.fillColor = Self.ink
                brow.bounds    = CGRect(
                    x     : 0,
                    y     : 0,
                    width : 240,
                    height: 170
                )
            }
            textLayer.path         = Self.textOutline
            textLayer.fillColor    = Self.ink
            textLayer.shadowOffset = CGSize(
                width : 0,
                height: Self.etchDepth
            )
            // Etched: each mark's upper lip shades the cut with a hair of shadow above it.
            for mark in [leftBrow, rightBrow, textLayer] as [CALayer] {
                mark.shadowColor   = CGColor(
                    gray : 0,
                    alpha: 1
                )
                mark.shadowOpacity = 0.45
                mark.shadowRadius  = 0
            }
            for layer in [body, lightLayer, leftBrow, rightBrow, textLayer] as [CALayer] {
                glassLayer.addSublayer(layer)
            }

            // Below the material, so the glass shows its own shadow blurred where it lies behind it.
            shadowLayer.addSublayer(wallShadow)
            shadowLayer.addSublayer(castLayer)
            shadowLayer.zPosition = -2

            effectView.material     = Self.material
            effectView.blendingMode = .withinWindow
            effectView.state        = .active
            effectView.autoresizingMask = [
                .width,
                .height,
            ]
            frostView.wantsLayer = true
            frostView.addSubview(effectView)
            frostView.layer?.zPosition = -1
            frostView.layer?.mask      = frostMask
            faceMask.cornerCurve = .continuous
            frostMask.addSublayer(faceMask)
            frostMask.addSublayer(rimMask)
            addSubview(frostView)

            for layer in [cords, rimLayer, glassLayer, nail] as [CALayer] {
                swingLayer.addSublayer(layer)
            }
            layer?.addSublayer(shadowLayer)
            layer?.addSublayer(swingLayer)
            updateContentsScale()
        }

        /// The outline of `HouseAwayPlaque.text` in `font`, its origin at the start of its baseline.
        private static let textOutline: CGPath = {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string    : HouseAwayPlaque.text,
                attributes: [.font: font]
            ))
            let path = CGMutablePath()
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count     = CTRunGetGlyphCount(run)
                var glyphs    = [CGGlyph](
                    repeating: 0,
                    count    : count
                )
                var positions = [CGPoint](
                    repeating: .zero,
                    count    : count
                )
                let all = CFRange(
                    location: 0,
                    length  : 0
                )
                CTRunGetGlyphs(
                    run,
                    all,
                    &glyphs
                )
                CTRunGetPositions(
                    run,
                    all,
                    &positions
                )
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont    = attributes[NSAttributedString.Key.font] as? NSFont ?? font
                for (glyph, position) in zip(glyphs, positions) {
                    guard let outline = CTFontCreatePathForGlyph(
                        runFont,
                        glyph,
                        nil
                    ) else { continue }
                    path.addPath(
                        outline,
                        transform: CGAffineTransform(
                            translationX: position.x,
                            y           : position.y
                        )
                    )
                }
            }
            return path
        }()

        /// Draws the brows' outlines for `brows`; `place` sizes and positions them.
        private func drawBrows() {
            withoutActions {
                leftBrow.path  = BrowOutlines.bundled.left[brows].map(MascotLayer.path)
                rightBrow.path = BrowOutlines.bundled.right[brows].map(MascotLayer.path)
            }
        }

        private func updateContentsScale() {
            let scale = window?.backingScaleFactor ?? 2
            for layer in [cords, edge, rimLayer, faceMask, rimMask, leftBrow, rightBrow, textLayer] as [CALayer] {
                layer.contentsScale = scale
            }
        }

        private func withoutActions(_ change: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }
    }
}
