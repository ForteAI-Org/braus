import MetalKit
import SwiftUI

/// HouseWorkerPortrait shows a worker outside its room as the room shows it: the room renderer's tilted,
/// standing worker without its floor or walls, the scene clipped to the body's projected silhouette, and
/// the brows on its projected face. It takes the silhouette's bounds in layout. With a seed the body
/// moves a little with its brows (`RoomBodyLink`), and the clip moves with it.
///
/// `size` is the side of the worker's sphere, as `MascotFace` takes it; the scene is the rows' square
/// room around that sphere at every size, so the worker reads the same in a row, at the top of its
/// conversation and in the shape picker, and each shape's silhouette is built once and scaled. A row
/// adds a faint status halo behind the body.
///
/// At the top of the conversation the worker is lit from below by its name's capsule (`capsuleLight`)
/// and a change of status cross-fades over `changeFade`; elsewhere a change cuts, as rooms do. A new
/// `preparation` squashes and stretches the whole worker once, as `MascotLayer.prepare()` does the flat
/// head. Under Reduce Motion a change cuts and nothing squashes; at rest nothing renders, and only the
/// brows' own Core Animation loop moves.
///
/// With a `switchStage`, the worker at the top of its conversation comes in on `HouseSwitch`'s beats
/// when it is first shown, and steps down once that stage turns to leaving.
struct HouseWorkerPortrait: View {
    let shape : WorkerShape
    let status: WorkerStatus

    /// The side of the worker's sphere, in points.
    var size: CGFloat = HouseWorkerPortrait.rowSize

    /// The brows' expression, or nil for the status's own.
    var brows: BrowState?

    /// The worker's seed, with which the brows play the status's behaviour (`MascotFace.behaviourSeed`).
    var seed: UInt64?

    var showsHalo = false

    /// The light of the name's capsule below the worker (`RoomLightUniforms.capsuleLight`), or zero.
    var capsuleLight = SIMD4<Float>.zero

    /// How long a change of status cross-fades, or nil for a cut (`RoomLightView.changeFade`).
    var changeFade: Double?

    /// Changing it squashes and stretches the worker once; its first value does not.
    var preparation = 0

    /// Where the worker is in a change of worker at the top of its conversation, or nil elsewhere.
    var switchStage: HouseSwitch.Stage?

    /// The rows' worker: the sphere of a scene 72.9 points across.
    static let rowSize = 2 * CGFloat(RoomLightUniforms.Shape.leftSphereShare) * 72.9

    /// The scene's lean, as in the rows: the camera faces the worker, which stands larger, its lamp a
    /// little to its left.
    static let lean: Float = 1

    /// The frame height a card gives the row-sized portrait: within the wide card and above the compact
    /// card's name, whatever the card's own height.
    static let frameHeight: CGFloat = 44

    // The projection scales with the scene, so each shape's outline is built once, one point across.
    private static let silhouettes = Dictionary(uniqueKeysWithValues: WorkerShape.allCases.map {
        ($0, makeSilhouette(of: $0))
    })

    /// The side of the square scene around a sphere of `size`.
    static func sceneSide(for size: CGFloat) -> CGFloat {
        size / (2 * CGFloat(RoomLightUniforms.Shape.leftSphereShare))
    }

    /// The silhouette of `shape` in a scene `side` points across, with y down from its top-left corner.
    static func silhouette(
        of shape: WorkerShape,
        side    : CGFloat
    ) -> Path {
        silhouettes[shape, default: Path()].applying(CGAffineTransform(
            scaleX: side,
            y     : side
        ))
    }

    var body: some View {
        let silhouette = Self.silhouette(
            of  : shape,
            side: Self.sceneSide(for: size)
        )
        let bounds = silhouette.boundingRect
        Figure(portrait: self)
            .frame(
                width : bounds.width,
                height: bounds.height
            )
            .background {
                if showsHalo && status != .off {
                    silhouette
                        .offsetBy(
                            dx: -bounds.minX,
                            dy: -bounds.minY
                        )
                        .fill(HouseLayout.light(of: status).opacity(0.16))
                        .blur(radius: 5)
                }
            }
            .allowsHitTesting(false)
    }

    /// The convex silhouette of the room's standing body, projected through its existing camera, in a
    /// scene one point across. Masking the room keeps its material, light sources and reflections on
    /// the worker only.
    private static func makeSilhouette(of shape: WorkerShape) -> Path {
        Path(RoomCamera.Perspective(
            size: CGSize(
                width : 1,
                height: 1
            ),
            lean: lean
        ).silhouette(of: shape))
    }

    /// Figure hosts the portrait's AppKit view.
    private struct Figure: NSViewRepresentable {
        let portrait: HouseWorkerPortrait

        func makeNSView(context: Context) -> HostView {
            let view = HostView()
            view.show(
                portrait,
                animated: false
            )
            return view
        }

        func updateNSView(
            _ view : HostView,
            context: Context
        ) {
            view.show(
                portrait,
                animated: true
            )
        }
    }

    /// HostView holds the scene's square, `figure`, placed so the silhouette fills its bounds: the room
    /// clipped to the silhouette, and the brows over it. A preparation transforms the square whole, so
    /// the body and its brows move as one.
    final class HostView: NSView {
        let figure = NSView()
        let face   = MascotFace.HostView()

        /// The room's light, or nil on a Mac with no Metal device, where only the brows show.
        private(set) var room: RoomLightView?

        /// Joins the room's renderer to the brows over the body.
        let bodyLink = RoomBodyLink()

        /// The sphere's and the scene's sides, and the silhouette in the scene, as last shown.
        private var size       : CGFloat = 0
        private var side       : CGFloat = 0
        private var silhouette = Path()

        /// The preparation last shown; nil before the first show.
        private var preparation: Int?

        /// Whether the change of worker's arrival waits for the first layout, which gives its foot.
        private var isArrivalPending = false

        private static let device = MTLCreateSystemDefaultDevice()

        static let prepareKey = "prepare"

        /// The keys of the change of worker's animations on the view's own layer, above `figure`, which
        /// the body link and a preparation move, so neither fights the other.
        static let switchKeys = (
            opacity  : "switchOpacity",
            transform: "switchTransform"
        )

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer        = true
            figure.wantsLayer = true
            figure.addSubview(face)
            addSubview(figure)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Shows `portrait`: its room's uniforms, its brows on the face the tilted camera shows, and a
        /// new preparation when `animated`.
        func show(
            _ portrait: HouseWorkerPortrait,
            animated  : Bool
        ) {
            size       = portrait.size
            side       = HouseWorkerPortrait.sceneSide(for: size)
            silhouette = HouseWorkerPortrait.silhouette(
                of  : portrait.shape,
                side: side
            )
            let uniforms = RoomLightUniforms(
                status      : portrait.status,
                shape       : portrait.shape,
                hasOccupant : true,
                camera      : .tilted,
                lean        : HouseWorkerPortrait.lean,
                capsuleLight: portrait.capsuleLight
            )
            if let room {
                room.changeFade = portrait.changeFade
                room.uniforms   = uniforms
            } else if let device = Self.device {
                let room = RoomLightView(
                    device  : device,
                    uniforms: uniforms
                )
                room.changeFade = portrait.changeFade
                figure.addSubview(
                    room,
                    positioned: .below,
                    relativeTo: face
                )
                self.room     = room
                bodyLink.room = room
            }
            // The room clips itself to the silhouette, which moves with the body.
            room?.silhouette = silhouette.cgPath
            MascotFace(
                shape           : portrait.shape,
                status          : portrait.status,
                brows           : portrait.brows ?? BrowState(portrait.status),
                size            : size,
                drawsBody       : false,
                catchesRoomLight: true,
                projectedFace   : RoomCamera.tilted.face(
                    of  : portrait.shape,
                    in  : CGSize(
                        width : side,
                        height: side
                    ),
                    lean: HouseWorkerPortrait.lean
                ),
                behaviourSeed   : portrait.seed,
                bodyLink        : bodyLink
            ).configure(
                face,
                animated: animated
            )
            if preparation == nil {
                face.mascot.startBreathing()
                isArrivalPending = portrait.switchStage.map { $0 != .leaving } ?? false
            } else if animated, preparation != portrait.preparation {
                prepare()
            }
            if portrait.switchStage == .leaving, layer?.opacity != 0 { leave() }
            preparation = portrait.preparation
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let bounds = silhouette.boundingRect
            // The silhouette's y points down from the scene's top, the views' up from its bottom.
            figure.frame = CGRect(
                x     : -bounds.minX,
                y     : bounds.maxY - side,
                width : side,
                height: side
            )
            face.frame  = figure.bounds
            room?.frame = figure.bounds
            room?.needsLayout = true
            if isArrivalPending, !bounds.isEmpty {
                isArrivalPending = false
                arrive()
            }
        }

        /// Brings the worker in after `HouseSwitch.entryDelay`: up from a little below on the arriving
        /// spring, fading in; under Reduce Motion, only the fade.
        private func arrive() {
            guard let layer else { return }
            let start = layer.convertTime(
                CACurrentMediaTime(),
                from: nil
            ) + HouseSwitch.entryDelay
            let reduces = RestylingMotion.reducesMotion
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue      = 0
            fade.toValue        = 1
            fade.duration       = HouseSwitch.arrival * (reduces ? 1 : 0.6)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.beginTime      = start
            fade.fillMode       = .backwards
            layer.add(
                fade,
                forKey: Self.switchKeys.opacity
            )
            guard !reduces else { return }

            let rise = CASpringAnimation(
                perceptualDuration: HouseSwitch.arrival,
                bounce            : HouseSwitch.bounce
            )
            rise.keyPath   = "transform"
            rise.fromValue = NSValue(caTransform3D: switchTransform(for: .arriving))
            rise.toValue   = NSValue(caTransform3D: CATransform3DIdentity)
            rise.duration  = rise.settlingDuration
            rise.beginTime = start
            rise.fillMode  = .backwards
            layer.add(
                rise,
                forKey: Self.switchKeys.transform
            )
        }

        /// Steps the worker down and fades it over `HouseSwitch.exit`, and keeps it hidden; under
        /// Reduce Motion, only the fade.
        private func leave() {
            guard let layer else { return }
            isArrivalPending = false
            let reduces = RestylingMotion.reducesMotion
            let from    = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey: Self.switchKeys.opacity)
            layer.removeAnimation(forKey: Self.switchKeys.transform)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            if !reduces { layer.transform = switchTransform(for: .leaving) }
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue      = from
            fade.toValue        = 0
            fade.duration       = HouseSwitch.exit
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(
                fade,
                forKey: Self.switchKeys.opacity
            )
            guard !reduces else { return }

            let step = CABasicAnimation(keyPath: "transform")
            step.fromValue      = NSValue(caTransform3D: CATransform3DIdentity)
            step.toValue        = NSValue(caTransform3D: layer.transform)
            step.duration       = HouseSwitch.exit
            step.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(
                step,
                forKey: Self.switchKeys.transform
            )
        }

        /// The view's transform at `stage`'s pose: lowered by its drop and scaled about its foot.
        private func switchTransform(for stage: HouseSwitch.Stage) -> CATransform3D {
            guard let layer else { return CATransform3DIdentity }
            let pose  = HouseSwitch.pose(
                stage,
                reducesMotion: false
            )
            // The layer scales about its anchor; the foot's centre is from there, y up.
            let pivot = CGPoint(
                x: (0.5 - layer.anchorPoint.x) * layer.bounds.width,
                y: -layer.anchorPoint.y * layer.bounds.height
            )
            var transform = CATransform3DMakeTranslation(
                pivot.x,
                pivot.y - pose.drop,
                0
            )
            transform = CATransform3DScale(
                transform,
                pose.scale,
                pose.scale,
                1
            )
            return CATransform3DTranslate(
                transform,
                -pivot.x,
                -pivot.y,
                0
            )
        }

        /// Squashes and stretches the whole worker once with `MascotLayer.prepare()`'s keyframes, about
        /// the foot of its silhouette, so it stays on the ground it stands on. Nothing under Reduce Motion.
        private func prepare() {
            guard !RestylingMotion.reducesMotion, let layer = figure.layer else { return }
            let bounds = silhouette.boundingRect
            // The layer turns about its anchor, AppKit's bottom-left corner; the pivot is from there, y up.
            let pivot  = CGPoint(
                x: bounds.midX - layer.anchorPoint.x * side,
                y: side - bounds.maxY - layer.anchorPoint.y * side
            )
            let lift   = size * MascotLayer.preparationLift
            let keys   = MascotLayer.preparationKeys
            let curve  = CAMediaTimingFunction(name: .easeInEaseOut)
            let squash = CAKeyframeAnimation(keyPath: "transform")
            squash.values = keys.times.indices.map { index in
                let lifted = CATransform3DMakeTranslation(
                    pivot.x,
                    pivot.y + keys.rise[index] * lift,
                    0
                )
                let scaled = CATransform3DScale(
                    lifted,
                    1 + keys.width[index],
                    1 + keys.height[index],
                    1
                )
                return NSValue(caTransform3D: CATransform3DTranslate(
                    scaled,
                    -pivot.x,
                    -pivot.y,
                    0
                ))
            }
            squash.keyTimes        = keys.times.map { NSNumber(value: $0) }
            squash.timingFunctions = Array(
                repeating: curve,
                count    : keys.times.count - 1
            )
            squash.duration        = RestylingTiming.preparation
            layer.add(
                squash,
                forKey: Self.prepareKey
            )
        }
    }
}
