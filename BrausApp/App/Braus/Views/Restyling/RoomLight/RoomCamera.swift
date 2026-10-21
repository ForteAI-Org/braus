//
//  RoomCamera.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CoreGraphics
import Foundation
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

    /// How high on the back wall the plaque's nail is, as a share of the wall's height in the cell.
    static let nailHeight = 0.9

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
        self == .tilted ? Perspective(
            size: size,
            lean: lean
        ).face(of: shape) : nil
    }

    /// Face is where a tilted room shows the worker's brows: the point they centre on, from the
    /// room's centre in points with y down, and how much wider and taller they show than from above.
    struct Face: Equatable {
        let anchor: CGVector
        let xScale: Double
        let yScale: Double
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
        /// projection stretches the face there, across and upward.
        func face(of shape: WorkerShape) -> Face {
            let radius  = Double(RoomLightUniforms.Shape(
                size: size,
                lean: lean
            ).sphereRadius)
            let outline = shape.outline
            let slab    = RoomCamera.slab(of: outline)
            // The face's point in front of `local`, a point of the outline in sphere radii with y down.
            func point(_ local: SIMD2<Double>) -> SIMD3<Double> {
                SIMD3(
                    bodyX + radius * local.x,
                    bodyDepth + radius * (slab + outline.faceHeight(at: local)),
                    radius * (outline.bottom - local.y)
                )
            }
            let brows  = SIMD2(0, -2 * RoomCamera.browLift * outline.inradius)
            let step   = 0.01
            let centre = point(brows)
            let right  = point(brows + SIMD2(step, 0))
            let up     = point(brows - SIMD2(0, step))
            let here   = project(centre)
            // Per length along the face, which curves away from the camera toward its edges.
            return Face(
                anchor: CGVector(
                    dx: here.x - size.width / 2,
                    dy: here.y - size.height / 2
                ),
                xScale: (project(right).x - here.x) / simd_distance(right, centre),
                yScale: (here.y - project(up).y) / simd_distance(up, centre)
            )
        }

        /// Where the plaque hangs on the back wall, behind the worker: its nail's place in the cell from
        /// its top-left corner, and the perspective's scale there.
        var plaqueNail: (x: Double, top: Double, scale: Double) {
            let nail  = SIMD3(bodyX, 0, RoomCamera.nailHeight * wallTop)
            let shown = project(nail)
            return (
                x    : Double(shown.x),
                top  : Double(shown.y),
                scale: scale(at: nail)
            )
        }
    }
}
