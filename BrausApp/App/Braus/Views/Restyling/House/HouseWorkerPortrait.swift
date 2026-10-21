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
        let size = CGSize(
            width : 1,
            height: 1
        )
        let camera = RoomCamera.Perspective(
            size: size,
            lean: lean
        )
        let radius = Double(RoomLightUniforms.Shape(
            size: size,
            lean: lean
        ).sphereRadius)
        let outline = shape.outline
        let slab = RoomCamera.slab(of: outline)
        var points: [CGPoint] = []
        for front in [-1.0, 1.0] {
            for index in 0...24 {
                let angle = Double.pi / 2 * Double(index) / 24
                let depth = front * radius * (slab + outline.corner * sin(angle))
                for point in outline.points(
                    growth       : outline.corner * cos(angle),
                    pointsPerTurn: 128
                ) {
                    points.append(camera.project(SIMD3(
                        camera.bodyX + radius * point.x,
                        camera.bodyDepth + depth,
                        radius * (outline.bottom - point.y)
                    )))
                }
            }
        }
        points.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func half(_ points: [CGPoint]) -> [CGPoint] {
            var hull: [CGPoint] = []
            for point in points {
                while hull.count >= 2 {
                    let a = hull[hull.count - 2]
                    let b = hull[hull.count - 1]
                    let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                    if cross > 0 { break }
                    hull.removeLast()
                }
                hull.append(point)
            }
            return hull
        }
        let hull = Array(half(points).dropLast()) + half(Array(points.reversed())).dropLast()
        return Path { path in
            path.addLines(hull)
            path.closeSubpath()
        }
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

        private static let device = MTLCreateSystemDefaultDevice()

        static let prepareKey = "prepare"

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
            } else if animated, preparation != portrait.preparation {
                prepare()
            }
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
