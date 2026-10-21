//
//  HouseAwayPlaque.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// HouseAwayPlaque is the sign hanging in an empty room while its worker is in the chat: a small
/// satin-metal plate on a cord from a nail, carrying the worker's brows and "In chat with you".
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

    /// What the plate says, and what the room's accessibility label adds.
    static let text = "In chat with you"

    func makeNSView(context: Context) -> PlaqueView {
        PlaqueView(
            brows    : brows,
            status   : status,
            isHanging: isHanging,
            camera   : camera
        )
    }

    func updateNSView(
        _ view : PlaqueView,
        context: Context
    ) {
        view.brows     = brows
        view.status    = status
        view.camera    = camera
        view.isHanging = isHanging
    }

    /// PlaqueView draws the plaque in layers over its room and moves it with Core Animation only.
    ///
    /// - The drop-in: when `isHanging` turns true, a spring on the plate's rotation about the nail
    ///   that settles in about a second; under Reduce Motion a fade.
    /// - The pendulum: while the room moves sideways the plate hangs on the same spring from its
    ///   nail. A change of the nail's speed throws it the other way and the speed leans it back, so
    ///   a room setting off to the left leaves the plate's foot to the right, and a room stopping
    ///   swings it on past rest; it never turns past `maximumTilt`. The nail's position is read when
    ///   the room's layout moves it, so nothing runs at rest. Under Reduce Motion it never tilts.
    /// - The size: the plate follows the room's short side, as the sphere does, and never takes more
    ///   than 70% of the room's width; the text stays 9 points and is left out where it cannot fit.
    ///   Seen through the tilted camera, it hangs high on the back wall at the wall's perspective
    ///   scale, facing the viewer so its text stays legible.
    /// - The light: a lit top edge and a sheen in the room's light, pulsing with the room on the
    ///   host clock, the sheen sliding as the plate turns under the lamp, and a soft shadow below
    ///   it; none of it in the room of a worker that is off.
    final class PlaqueView: NSView {

        /// The worker's expression, drawn small on the plate.
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

        /// Whether the plaque hangs in the room; turning true drops it in.
        var isHanging: Bool {
            didSet {
                guard isHanging != oldValue else { return }
                if isHanging {
                    hang()
                } else {
                    takeDown()
                }
            }
        }

        /// The rotation about the nail, and with it the cord and the plate.
        let swingLayer = CALayer()

        /// The room's light on the plate, pulsing with the room.
        let lightLayer = CAGradientLayer()

        static let swingKey = "swing"
        static let fadeKey  = "fade"
        static let pulseKey = "pulse"

        /// The plate's turn at its widest, in radians, either way.
        static let maximumTilt = 7 * Double.pi / 180

        /// The share of `maximumTilt` the plate leans at most behind a nail moving steadily.
        static let maximumLean = 0.3

        /// The nail's speed, in points per second, that leans the plate fully.
        static let fullLeanSpeed = 240.0

        /// How much the plate's turning speed, in radians per second, changes against each point per
        /// second the nail's speed changes: a nail that sets off pushes the plate back, one that
        /// stops throws it forward.
        static let inertia = 0.005

        /// The pause in the nail's movement that counts as a stop.
        private static let stopPause = Duration.milliseconds(60)

        /// How far the plate starts turned when it drops in, in radians.
        private static let dropAngle = 0.32

        private static let fadeSeconds = 0.2

        private static let font = NSFont.systemFont(
            ofSize: 9,
            weight: .medium
        )

        /// The brows' and the text's colour, the design's off-white.
        private static let ink = CGColor(
            srgbRed: 245.0 / 255,
            green  : 245.0 / 255,
            blue   : 247.0 / 255,
            alpha  : 1
        )

        private let cord      = CAShapeLayer()
        private let nail      = CALayer()
        private let plateBody = CAGradientLayer()
        private let sheen     = CAGradientLayer()
        private let leftBrow  = CAShapeLayer()
        private let rightBrow = CAShapeLayer()
        private let label     = CATextLayer()

        /// The plate's turn in the model, where every animation ends.
        private var angle = 0.0

        /// The plate's width, which the sheen travels a share of.
        private var plateWidth: CGFloat = 0

        /// Whether the text was shown at the last layout, so that a change fades.
        private var showsText: Bool?

        /// The spring the plate is on, from which its angle and speed at any moment follow; nil
        /// at rest.
        private(set) var swing: Swing?

        /// The nail's last position in the window and when it was read, and its speed.
        private var anchor        : (x: CGFloat, time: CFTimeInterval)?
        private var anchorVelocity = 0.0
        private var stopTask      : Task<Void, Never>?

        init(
            brows    : BrowState,
            status   : WorkerStatus,
            isHanging: Bool,
            camera   : RoomCamera = .top
        ) {
            self.brows     = brows
            self.status    = status
            self.camera    = camera
            self.isHanging = isHanging
            super.init(frame: .zero)
            wantsLayer = true
            build()
            drawBrows()
            swingLayer.isHidden = !isHanging
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
                camera: camera
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

        /// Brings the plaque down: a swing that settles at rest, or a fade under Reduce Motion.
        func hang() {
            stopTask?.cancel()
            anchor         = nil
            anchorVelocity = 0
            showsText      = nil
            arrange()
            applyLight()
            withoutActions { swingLayer.isHidden = false }
            swingLayer.removeAnimation(forKey: Self.fadeKey)
            guard !RestylingMotion.reducesMotion else {
                rest()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue   = 1
                fade.duration  = Self.fadeSeconds
                swingLayer.add(
                    fade,
                    forKey: Self.fadeKey
                )
                return
            }
            play(Swing(
                from    : Self.dropAngle,
                velocity: 0,
                target  : 0,
                start   : CACurrentMediaTime()
            ))
        }

        /// The plate's lean, in radians, behind a nail moving sideways at `velocity` points per
        /// second: a nail moving left turns it counterclockwise, which keeps its foot to the right (the
        /// view's layer has its y axis up). At most `maximumLean` of `maximumTilt`; zero under Reduce
        /// Motion.
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

        /// Reads the nail's position in the window, once the layout has moved the room.
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

        /// Moves the plate after its nail, now at `x` points in the window at `time`: a change of the
        /// nail's speed throws the plate the other way (`inertia`) and its speed leans the plate back,
        /// within `maximumTilt`. Once the nail pauses for `stopPause`, it has stopped: the plate swings
        /// on the way the nail went, past rest, and settles. Nothing under Reduce Motion.
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

        /// The nail has stopped at `time`: its speed drops to zero at once, which throws the plate
        /// on the way the nail went, and the plate swings back to rest.
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
        /// speed changed against `kicked`, the nail's change of speed. The speed is cut so that no
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

        /// Animates the plate's rotation, and the sheen with it, along `next`.
        private func play(_ next: Swing) {
            swing = next
            set(angle: next.target)
            for (layer, keyPath, from, to) in [
                (swingLayer as CALayer, "transform.rotation.z", next.from, next.target),
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
            swingLayer.removeAnimation(forKey: Self.swingKey)
            sheen.removeAnimation(forKey: Self.swingKey)
            set(angle: 0)
        }

        private func set(angle: Double) {
            self.angle = angle
            withoutActions {
                swingLayer.setValue(
                    angle,
                    forKeyPath: "transform.rotation.z"
                )
                sheen.position.x = sheenX(for: angle)
            }
        }

        /// Where the sheen sits on the plate turned by `angle`: the lamp stays put while the plate
        /// turns under it, so the sheen slides against the turn, a fifth of the plate at full tilt.
        private func sheenX(for angle: Double) -> Double {
            Double(plateWidth) * (0.5 - 0.2 * angle / Self.maximumTilt)
        }

        private func takeDown() {
            stopTask?.cancel()
            stopTask       = nil
            anchor         = nil
            anchorVelocity = 0
            withoutActions {
                swingLayer.removeAllAnimations()
                lightLayer.removeAnimation(forKey: Self.pulseKey)
                swingLayer.isHidden = true
            }
            rest()
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

        /// Lights the plate with the room's light, pulsing with it while the plaque hangs in a window,
        /// or leaves it unlit, with no shadow, when the worker is off.
        private func applyLight() {
            lightLayer.removeAnimation(forKey: Self.pulseKey)
            guard let light = status.light else {
                withoutActions {
                    lightLayer.isHidden     = true
                    plateBody.shadowOpacity = 0
                }
                return
            }
            let strength = status.lightStrength
            func color(_ share: Double) -> CGColor {
                CGColor(
                    srgbRed: light.red,
                    green  : light.green,
                    blue   : light.blue,
                    alpha  : share * strength
                )
            }
            withoutActions {
                lightLayer.isHidden     = false
                lightLayer.colors       = [color(0.36), color(0.12), color(0)]
                sheen.colors            = [color(0), color(0.22), color(0)]
                plateBody.shadowOpacity = Float(0.4 * strength)
            }
            let weights = RoomLightView.pulseWeights(
                for          : status,
                reducesMotion: RestylingMotion.reducesMotion
            )
            // Only a hanging plaque pulses; the hidden ones in occupied rooms cost nothing.
            guard
                isHanging,
                window != nil,
                let first = weights.first,
                let cycle = RoomLightView.pulseCycle(for: status)
            else { return }
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values          = (weights + [first]).map { NSNumber(value: $0) }
            pulse.keyTimes        = (0...weights.count).map { NSNumber(value: Double($0) / Double(weights.count)) }
            pulse.calculationMode = .linear
            pulse.duration        = cycle
            pulse.repeatCount     = .infinity
            pulse.beginTime       = RoomLightView.pulseBeginTime(in: lightLayer)
            lightLayer.add(
                pulse,
                forKey: Self.pulseKey
            )
        }

        // MARK: Drawing

        /// Metrics is the plaque's geometry in a room of a given size, in points.
        struct Metrics {

            /// The plaque's size against the one in a room whose short side is 104 points.
            let scale: CGFloat

            let plate    : CGSize
            let drop     : CGFloat
            let showsText: Bool

            /// The nail's distance below the room's top edge.
            let top: CGFloat

            /// The least margin beside the text.
            static let textMargin: CGFloat = 5

            /// The text's width at its 9 points.
            static let textWidth = NSAttributedString(
                string    : HouseAwayPlaque.text,
                attributes: [.font: PlaqueView.font]
            ).size().width.rounded(.up)

            /// The plaque in a room of `room` points seen through `camera`: in a tilted room the nail is
            /// high on the back wall and the plaque takes the wall's perspective scale there.
            init(
                room  : CGSize,
                camera: RoomCamera = .top
            ) {
                let nail   = camera == .tilted ? RoomCamera.Perspective(size: room).plaqueNail : nil
                let widest = 0.7 * room.width
                let lined  = Self.textWidth + 2 * Self.textMargin
                scale     = max(0, min(1, min(room.width, room.height) / 104)) * (nail?.scale ?? 1)
                showsText = lined <= widest && scale >= 0.75
                plate = CGSize(
                    width : max(0, min(widest, showsText ? max(88 * scale, lined) : 88 * scale)),
                    height: 30 * scale
                )
                drop = 9 * scale
                top  = nail?.top ?? max(
                    4,
                    (room.height - HouseLayout.nameBand - plate.height - drop) / 2
                )
            }
        }

        private func place(_ metrics: Metrics) {
            let scale = metrics.scale
            let plate = metrics.plate
            let total = CGSize(
                width : plate.width,
                height: plate.height + metrics.drop
            )
            plateWidth = plate.width
            // Turning about the nail at the top centre; the view's layer has its y axis up.
            swingLayer.bounds = CGRect(
                origin: .zero,
                size  : total
            )
            swingLayer.anchorPoint = CGPoint(
                x: 0.5,
                y: 1
            )
            swingLayer.position = CGPoint(
                x: bounds.midX,
                y: bounds.maxY - metrics.top
            )

            nail.frame = CGRect(
                x     : total.width / 2 - 1.5 * scale,
                y     : total.height - 3 * scale,
                width : 3 * scale,
                height: 3 * scale
            )
            nail.cornerRadius = 1.5 * scale

            let inset = 16 * scale
            let path  = CGMutablePath()
            path.move(to: CGPoint(
                x: inset,
                y: plate.height
            ))
            path.addLine(to: CGPoint(
                x: total.width / 2,
                y: total.height - 1.5 * scale
            ))
            path.addLine(to: CGPoint(
                x: total.width - inset,
                y: plate.height
            ))
            cord.path = path

            let corner = 7 * scale
            plateBody.frame = CGRect(
                origin: .zero,
                size  : plate
            )
            plateBody.cornerRadius = corner
            plateBody.shadowRadius = 4 * scale
            plateBody.shadowOffset = CGSize(
                width : 0,
                height: -3 * scale
            )
            // A given path spares Core Animation from tracing the plate's shadow every frame.
            plateBody.shadowPath = CGPath(
                roundedRect : plateBody.bounds,
                cornerWidth : corner,
                cornerHeight: corner,
                transform   : nil
            )
            lightLayer.frame        = plateBody.bounds
            lightLayer.cornerRadius = corner
            // The sheen keeps to the plate's upper part, above the text, which stays legible.
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

            let textBottom = max(2, 0.17 * plate.height)
            label.frame = CGRect(
                x     : 0,
                y     : textBottom,
                width : plate.width,
                height: 12
            )
            label.opacity = metrics.showsText ? 1 : 0

            let span      = 22 * scale
            let sideWidth = span * 0.455
            let browScale = sideWidth / 240
            // The brows are centred in the space above the text's capitals, or on the plate without text.
            let capTop = textBottom + label.frame.height - Self.font.ascender + Self.font.capHeight
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
            }
        }

        private func build() {
            nail.backgroundColor = CGColor(
                gray : 0.62,
                alpha: 1
            )

            cord.fillColor   = nil
            cord.strokeColor = CGColor(
                gray : 0.5,
                alpha: 0.9
            )
            cord.lineWidth = 0.75

            // Satin metal: a soft vertical sheen, a light top edge and a hair of rim.
            plateBody.colors = [
                CGColor(gray: 0.36, alpha: 1),
                CGColor(gray: 0.27, alpha: 1),
                CGColor(gray: 0.21, alpha: 1),
            ]
            plateBody.locations   = [0, 0.45, 1]
            plateBody.startPoint  = CGPoint(x: 0.5, y: 1)
            plateBody.endPoint    = CGPoint(x: 0.5, y: 0)
            plateBody.cornerCurve = .continuous
            plateBody.borderWidth = 0.5
            plateBody.borderColor = CGColor(gray: 1, alpha: 0.16)
            plateBody.shadowColor = CGColor(gray: 0, alpha: 1)

            // The lamp is above the plate, so its light is strongest on the top edge.
            lightLayer.locations     = [0, 0.32, 0.68]
            lightLayer.startPoint    = CGPoint(x: 0.5, y: 1)
            lightLayer.endPoint      = CGPoint(x: 0.5, y: 0)
            lightLayer.cornerCurve   = .continuous
            lightLayer.masksToBounds = true
            sheen.startPoint = CGPoint(x: 0, y: 0.5)
            sheen.endPoint   = CGPoint(x: 1, y: 0.5)
            lightLayer.addSublayer(sheen)

            for brow in [leftBrow, rightBrow] {
                brow.fillColor = Self.ink
                brow.bounds    = CGRect(
                    x     : 0,
                    y     : 0,
                    width : 240,
                    height: 170
                )
            }

            label.string = NSAttributedString(
                string    : HouseAwayPlaque.text,
                attributes: [
                    .font           : Self.font,
                    .foregroundColor: NSColor(cgColor: Self.ink)?.withAlphaComponent(0.86) ?? .secondaryLabelColor,
                ]
            )
            label.alignmentMode = .center

            plateBody.addSublayer(lightLayer)
            plateBody.addSublayer(leftBrow)
            plateBody.addSublayer(rightBrow)
            plateBody.addSublayer(label)
            swingLayer.addSublayer(cord)
            swingLayer.addSublayer(plateBody)
            swingLayer.addSublayer(nail)
            layer?.addSublayer(swingLayer)
        }

        /// Draws the brows' outlines for `brows`; `place` sizes and positions them.
        private func drawBrows() {
            withoutActions {
                leftBrow.path  = BrowOutlines.bundled.left[brows].map(MascotLayer.path)
                rightBrow.path = BrowOutlines.bundled.right[brows].map(MascotLayer.path)
            }
        }

        private func updateContentsScale() {
            let scale = window?.backingScaleFactor ?? 2
            for layer in [label, cord, leftBrow, rightBrow] as [CALayer] {
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
