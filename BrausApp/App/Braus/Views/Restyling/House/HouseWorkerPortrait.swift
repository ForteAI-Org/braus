import MetalKit
import SwiftUI

/// HouseWorkerPortrait shows the room renderer's tilted worker without its floor or walls.
/// Its projected silhouette clips the scene and moves with the body; a faint status halo sits behind
/// the body.
struct HouseWorkerPortrait: View {
    let shape : WorkerShape
    let status: WorkerStatus
    let seed  : UInt64

    /// Joins the portrait's renderer to the brows over the body.
    @State private var bodyLink = RoomBodyLink()

    static let sceneSize = CGSize(
        width : 72.9,
        height: 72.9
    )
    static let lean: Float = 1

    // The portrait size is fixed, so each shape's projected outline is built once.
    private static let silhouettes = Dictionary(uniqueKeysWithValues: WorkerShape.allCases.map {
        ($0, makeSilhouette(of: $0))
    })

    static func silhouette(of shape: WorkerShape) -> Path {
        silhouettes[shape, default: Path()]
    }

    var body: some View {
        let size = Self.sceneSize
        let lean = Self.lean
        let silhouette = Self.silhouette(of: shape)
        let radius = RoomLightUniforms.Shape(
            size: size,
            lean: lean
        ).sphereRadius
        return ZStack {
            if status != .off {
                silhouette
                    .fill(HouseLayout.light(of: status).opacity(0.16))
                    .blur(radius: 5)
            }
            Light(
                uniforms  : RoomLightUniforms(
                    status     : status,
                    shape      : shape,
                    hasOccupant: true,
                    camera     : .tilted,
                    lean       : lean
                ),
                silhouette: silhouette.cgPath,
                bodyLink  : bodyLink
            )

            MascotFace(
                shape           : shape,
                status          : status,
                brows           : BrowState(status),
                size            : CGFloat(2 * radius),
                drawsBody       : false,
                catchesRoomLight: true,
                projectedFace   : RoomCamera.tilted.face(
                    of  : shape,
                    in  : size,
                    lean: lean
                ),
                behaviourSeed   : seed,
                bodyLink        : bodyLink
            )
        }
        .frame(
            width : size.width,
            height: size.height
        )
        .offset(y: size.height / 2 - silhouette.boundingRect.midY)
        .frame(
            width : 56,
            height: HouseLayout.rowHeight
        )
        .allowsHitTesting(false)
    }

    /// The convex silhouette of the room's standing body, projected through its existing camera.
    /// Masking the room keeps its material, light sources and reflections on the worker only.
    private static func makeSilhouette(of shape: WorkerShape) -> Path {
        let size = sceneSize
        let lean = Self.lean
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

    private struct Light: NSViewRepresentable {
        let uniforms  : RoomLightUniforms
        let silhouette: CGPath
        let bodyLink  : RoomBodyLink
        private static let device = MTLCreateSystemDefaultDevice()

        func makeNSView(context: Context) -> NSView {
            guard let device = Self.device else { return NSView() }
            let view = RoomLightView(
                device  : device,
                uniforms: uniforms
            )
            view.silhouette = silhouette
            bodyLink.room   = view
            return view
        }

        func updateNSView(
            _ view : NSView,
            context: Context
        ) {
            guard let view = view as? RoomLightView else { return }
            view.uniforms   = uniforms
            view.silhouette = silhouette
            bodyLink.room   = view
        }
    }
}
