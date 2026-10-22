//
//  RoomCamera.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CoreGraphics
import Foundation
import os
import simd

/// RoomCamera is how a room is seen: straight down onto its floor plan, or, as a trial to compare
/// with it, tilted into the room with perspective so its depth shows.
///
/// The tilted camera looks through the room's cell as through a window that spans the floor's front
/// edge, the cell's bottom, to the back wall's top, the cell's top: the floor recedes up the cell, the
/// back wall rises above it, the side walls narrow toward it, and nothing outside the room shows. The
/// camera stands on the window's axis, in front of it and above, `tilt` from vertical. Seen this way the
/// worker stands on the floor, its outline upright and facing the camera, `thickness` of its width
/// from front to back. Where the composition leans left, as in the rows, the camera stands across
/// from the worker instead of the middle, still looking through the whole cell, so the worker is seen
/// head on and the room recedes to the right. The house reads `BRAUS_ROOM_CAMERA` once at launch:
/// `top` for the view from above, or `tilted` by default.
nonisolated enum RoomCamera: String, Sendable {
    case top
    case tilted

    /// The camera a value of `BRAUS_ROOM_CAMERA` names, the tilted one for any other value or none.
    init(environment value: String?) {
        self = value.flatMap(RoomCamera.init(rawValue:)) ?? .tilted
    }

    /// The camera of the house's rooms, read once at launch.
    static let launch = RoomCamera(environment: ProcessInfo.processInfo.environment["BRAUS_ROOM_CAMERA"])

    /// The tilted camera's angle from vertical, and its vertical field of view, in radians.
    static let tilt        = 40 * Double.pi / 180
    static let fieldOfView = 45 * Double.pi / 180

    /// Where the worker stands, as a share of the floor's depth from the back wall: a little behind
    /// the middle.
    static let bodyDepth = 0.45

    /// Where the tilted room's lamp hangs, as RoomLight.metal places it: its height and how far behind
    /// the worker, as shares of the room's short side, and how far left of a worker in a room leaning
    /// left (`lampHeightShare`, `lampBehind` and `lampLead` there).
    static let lampHeight = 0.7
    static let lampBehind = 0.2
    static let lampLead   = 0.15

    /// The radius of the coves where the tilted room's walls meet its floor, as a share of the
    /// room's short side.
    static let filletShare = 0.08

    /// How far above the middle of a standing worker's front face its brows' line sits, as a share of
    /// the face's width: higher than from above (`MascotLayer.browLift`), where the face turns toward
    /// the camera looking down on it.
    static let browLift = 0.38

    /// How thick a standing worker is from front to back, as a share of its outline's width or height,
    /// whichever is less, so the wide capsule and lens do not read as drums; the circle stays a sphere.
    static let thickness = 0.65

    /// How far a standing worker's core is thickened before and behind its middle, in sphere radii:
    /// enough with the bevel and the dome for `thickness`, and none where they alone are as thick.
    static func slab(of outline: ShapeOutline) -> Double {
        let side = min(outline.halfSize.width, outline.halfSize.height)
        return max(0, thickness * side - outline.corner - outline.dome)
    }

    /// Where the brows of a worker of `shape` show in a room of `size` whose composition leans `lean`
    /// to the left, seen by this camera; nil from above, where they keep their place on the face.
    func face(
        of shape: WorkerShape,
        in size : CGSize,
        lean    : Float = 0
    ) -> Face? {
        guard self == .tilted else { return nil }
        let key = FaceKey(
            shape : shape,
            width : size.width,
            height: size.height,
            lean  : lean
        )
        if let face = Self.faces.withLock({ $0[key] }) { return face }
        let face = Perspective(
            size: size,
            lean: lean
        ).face(of: shape)
        Self.faces.withLock { faces in
            // ponytail: a resize misses at every size it passes; a full reset past 512 keeps it small.
            if faces.count > 512 { faces.removeAll() }
            faces[key] = face
        }
        return face
    }

    /// FaceKey is what a tilted room's face depends on.
    private struct FaceKey: Hashable {
        let shape : WorkerShape
        let width : CGFloat
        let height: CGFloat
        let lean  : Float
    }

    /// The faces found so far: every room asks again for its own at each update of its view, and
    /// finding one walks the outline many times.
    private static let faces = OSAllocatedUnfairLock<[FaceKey: Face?]>(initialState: [:])

    /// Face is where a tilted room shows the worker's brows: the point they centre on, from the
    /// room's centre in points with y down, how much wider and taller they show than from above, and
    /// how far their line turns on screen, in radians, counterclockwise with y up.
    struct Face: Equatable {
        let anchor: CGVector
        let xScale: Double
        let yScale: Double
        var turn  : Double = 0
    }

    /// Perspective is the tilted camera for a room of a given size.
    ///
    /// Scene units are points: x to the right, y from the back wall toward the camera, z up from the
    /// floor, as in RoomLight.metal. The window's slant length is the cell's height, so its foot is
    /// `depth` from the back wall and its top `wallTop` above the floor; the eye stands `focal` in front
    /// of the window, across from the worker. The worker stands `bodyX` from the left wall, where
    /// `RoomLightUniforms.Shape.bodyX` shows it: the middle, or the left in a room leaning left.
    /// RoomLight.metal derives the same camera from `packed` and the stage.
    struct Perspective {
        let size     : CGSize
        let lean     : Float
        let depth    : Double
        let wallTop  : Double
        let focal    : Double
        let bodyDepth: Double
        let bodyX    : Double

        private let centre: SIMD3<Double>
        private let normal: SIMD3<Double>
        private let up    : SIMD3<Double>

        init(
            size: CGSize,
            lean: Float = 0
        ) {
            let width  = Double(size.width)
            let height = Double(size.height)
            self.size = size
            self.lean = lean
            depth     = height * cos(RoomCamera.tilt)
            wallTop   = height * sin(RoomCamera.tilt)
            focal     = height / 2 / tan(RoomCamera.fieldOfView / 2)
            bodyDepth = RoomCamera.bodyDepth * depth
            centre    = SIMD3(width / 2, depth / 2, wallTop / 2)
            normal    = SIMD3(0, wallTop, depth) / max(height, 1e-9)
            up        = SIMD3(0, -depth, wallTop) / max(height, 1e-9)
            bodyX     = Double(RoomLightUniforms.Shape.bodyX(
                in  : size,
                lean: lean
            ))
        }

        /// The radius of the coves where the walls meet the floor.
        var fillet: Double {
            RoomCamera.filletShare * Double(min(size.width, size.height))
        }

        /// How far the floor reaches from the back wall: far past the window, so no front wall shows.
        /// RoomLight.metal's `footprintReach` is the same share.
        var footprintDepth: Double {
            2 * depth
        }

        /// How high the walls rise: past the back wall's top, where the window meets it.
        var wallHeight: Double {
            1.15 * wallTop
        }

        /// The camera as RoomLight.metal reads it: the floor's depth, the back wall's top, the focal
        /// length and the worker's distance from the back wall, in points.
        var packed: SIMD4<Float> {
            SIMD4(
                Float(depth),
                Float(wallTop),
                Float(focal),
                Float(bodyDepth)
            )
        }

        /// Where `point` shows in the cell, in points from its top-left corner with y down: across, its
        /// offset from the eye, which stands across from the worker, shrinks with its distance.
        func project(_ point: SIMD3<Double>) -> CGPoint {
            let offset = point - centre
            let scale  = self.scale(at: point)
            return CGPoint(
                x: bodyX + scale * (point.x - bodyX),
                y: Double(size.height) / 2 - scale * simd_dot(offset, up)
            )
        }

        /// How large something at `point` shows against the same thing in the window's plane.
        func scale(at point: SIMD3<Double>) -> Double {
            focal / max(focal - simd_dot(point - centre, normal), 1e-9)
        }

        /// The scene as the eye sees it, in points: x to the right, y up the window and z from the eye
        /// toward the window, which stands `focal` away. The eye stands across from the worker.
        var worldToView: simd_float4x4 {
            var eye = centre + focal * normal
            eye.x   = bodyX
            func row(_ axis: SIMD3<Double>) -> SIMD4<Float> {
                SIMD4(
                    SIMD3<Float>(axis),
                    Float(-simd_dot(axis, eye))
                )
            }
            return simd_float4x4(rows: [
                row(SIMD3(1, 0, 0)),
                row(up),
                row(-normal),
                SIMD4(0, 0, 0, 1),
            ])
        }

        /// The view projected onto the window, x and y from -1 to 1 across it with y up, and the depth
        /// reversed and unbounded: 1 at `near` points from the eye, nearing 0 far away. Off the window's
        /// middle, as in a room leaning left, the eye sees the window shifted across.
        func viewToClip(near: Float) -> simd_float4x4 {
            let shift = 2 * bodyX / Double(size.width) - 1
            return simd_float4x4(rows: [
                SIMD4(Float(2 * focal / Double(size.width)), 0, Float(shift), 0),
                SIMD4(0, Float(2 * focal / Double(size.height)), 0, 0),
                SIMD4(0, 0, 0, near),
                SIMD4(0, 0, 1, 0),
            ])
        }

        /// The brows of `shape` as this camera sees them: on the standing body's front face,
        /// `RoomCamera.browLift` of the face's width above its middle, projected, and stretched as the
        /// projection stretches the face there, across and upward; with the body moved by `pose`.
        func face(
            of shape: WorkerShape,
            pose    : RoomLightUniforms.Pose = .rest
        ) -> Face {
            let radius  = Double(RoomLightUniforms.Shape(
                size: size,
                lean: lean
            ).sphereRadius)
            let outline = shape.outline
            let slab    = RoomCamera.slab(of: outline)
            // The face's point in front of `local`, a point of the outline in sphere radii with y down.
            func point(_ local: SIMD2<Double>) -> SIMD3<Double> {
                pose.moved(
                    SIMD3(
                        bodyX + radius * local.x,
                        bodyDepth + radius * (slab + outline.faceHeight(at: local)),
                        radius * (outline.bottom - local.y)
                    ),
                    foot: SIMD3(bodyX, bodyDepth, 0)
                )
            }
            let brows  = SIMD2(0, -2 * RoomCamera.browLift * outline.inradius)
            let step   = 0.01
            let centre = point(brows)
            let right  = point(brows + SIMD2(step, 0))
            let up     = point(brows - SIMD2(0, step))
            let here   = project(centre)
            // Per length along the face, which curves away from the camera toward its edges.
            let across = project(right)
            return Face(
                anchor: CGVector(
                    dx: here.x - size.width / 2,
                    dy: here.y - size.height / 2
                ),
                xScale: (across.x - here.x) / simd_distance(right, centre),
                yScale: (here.y - project(up).y) / simd_distance(up, centre),
                turn  : atan2(here.y - across.y, across.x - here.x)
            )
        }

        /// The silhouette of the standing body of `shape` moved by `pose`, as this camera shows it, in
        /// the cell's points with y down: `samples` points of its convex hull, where rays from the hull's
        /// middle at even turns leave it, so silhouettes of every pose have the same points in the same
        /// order and Core Animation can carry one into the next.
        func silhouette(
            of shape: WorkerShape,
            pose    : RoomLightUniforms.Pose,
            samples : Int = 96
        ) -> CGPath {
            // A coarser hull than the one at rest, enough for a clip that moves.
            let hull   = self.hull(
                of   : shape,
                pose : pose,
                rings: 8,
                turn : 48
            )
            let middle = CGPoint(
                x: hull.map(\.x).reduce(0, +) / CGFloat(max(1, hull.count)),
                y: hull.map(\.y).reduce(0, +) / CGFloat(max(1, hull.count))
            )
            let points = (0..<samples).map { index -> CGPoint in
                let angle = 2 * Double.pi * Double(index) / Double(samples)
                let ray   = CGVector(
                    dx: cos(angle),
                    dy: sin(angle)
                )
                // The nearest crossing of the ray with the hull's edges, which surround the middle.
                var reach = CGFloat.greatestFiniteMagnitude
                for (start, end) in zip(hull, hull.dropFirst() + hull.prefix(1)) {
                    let edge  = CGVector(
                        dx: end.x - start.x,
                        dy: end.y - start.y
                    )
                    let cross = ray.dx * edge.dy - ray.dy * edge.dx
                    guard abs(cross) > 1e-12 else { continue }
                    let along = ((start.x - middle.x) * edge.dy - (start.y - middle.y) * edge.dx) / cross
                    let share = ((start.x - middle.x) * ray.dy - (start.y - middle.y) * ray.dx) / cross
                    if along > 0, (-1e-9...1 + 1e-9).contains(share) { reach = min(reach, along) }
                }
                return reach == .greatestFiniteMagnitude ? middle : CGPoint(
                    x: middle.x + ray.dx * reach,
                    y: middle.y + ray.dy * reach
                )
            }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            return path
        }

        /// The convex silhouette of the standing body of `shape`, as this camera shows it at rest, in the
        /// cell's points with y down: the hull of its outline grown along the bevel before and behind.
        func silhouette(of shape: WorkerShape) -> CGPath {
            let hull = self.hull(
                of  : shape,
                pose: .rest
            )
            let path = CGMutablePath()
            path.addLines(between: hull)
            path.closeSubpath()
            return path
        }

        /// The convex hull of the standing body of `shape` moved by `pose`, projected, clockwise on
        /// screen, from `rings` rings of the bevel before and behind, `turn` points each.
        private func hull(
            of shape: WorkerShape,
            pose    : RoomLightUniforms.Pose,
            rings   : Int = 24,
            turn    : Int = 128
        ) -> [CGPoint] {
            let radius  = Double(RoomLightUniforms.Shape(
                size: size,
                lean: lean
            ).sphereRadius)
            let outline = shape.outline
            let slab    = RoomCamera.slab(of: outline)
            var points: [CGPoint] = []
            for front in [-1.0, 1.0] {
                for index in 0...rings {
                    let angle = Double.pi / 2 * Double(index) / Double(rings)
                    let depth = front * radius * (slab + outline.corner * sin(angle))
                    for point in outline.points(
                        growth       : outline.corner * cos(angle),
                        pointsPerTurn: turn
                    ) {
                        points.append(project(pose.moved(
                            SIMD3(
                                bodyX + radius * point.x,
                                bodyDepth + depth,
                                radius * (outline.bottom - point.y)
                            ),
                            foot: SIMD3(bodyX, bodyDepth, 0)
                        )))
                    }
                }
            }
            points.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            func half(_ points: [CGPoint]) -> [CGPoint] {
                var hull: [CGPoint] = []
                for point in points {
                    while hull.count >= 2 {
                        let a     = hull[hull.count - 2]
                        let b     = hull[hull.count - 1]
                        let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                        if cross > 0 { break }
                        hull.removeLast()
                    }
                    hull.append(point)
                }
                return hull
            }
            return Array(half(points).dropLast()) + half(Array(points.reversed())).dropLast()
        }

        /// The centre of the lamp's disc: over the worker, a little behind it, and in a room leaning
        /// left a little left of it.
        var lamp: SIMD3<Double> {
            let side = Double(min(size.width, size.height))
            return SIMD3(
                bodyX - RoomCamera.lampLead * side * Double(lean),
                bodyDepth - RoomCamera.lampBehind * side,
                RoomCamera.lampHeight * side
            )
        }
    }
}
