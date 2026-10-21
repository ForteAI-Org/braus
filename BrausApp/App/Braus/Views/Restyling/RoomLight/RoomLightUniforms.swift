//
//  RoomLightUniforms.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// RoomLightUniforms is what a room's light depends on: the worker's status light, its shape,
/// whether the worker is in the room, the camera the room is seen through, and how far its
/// composition leans to the left.
///
/// Colours are sRGB components in 0...1; the shaders linearise them. Every worker's body is the
/// same graphite metal, so only its shape reaches the shaders.
///
/// Seen through the tilted camera, a busy worker in its room also has its screen, a second, cool light
/// in front of it (`screenStrength`), and a room that is off has the moon instead of its lamp
/// (`moonStrength`).
///
/// At `lean` 0 the worker stands at the room's centre under its lamp, with the pool around it, as on
/// the floor plan. At 1, as in the rows, it stands larger at the left, the lamp above it and a little
/// further left, and the pool spreads from it toward the right, fading into the room's darker right
/// side; values between are the way from one to the other while a row reshapes.
nonisolated struct RoomLightUniforms: Equatable {
    var lightColor : SIMD3<Float>
    var strength   : Float
    var shape      : WorkerShape
    var hasOccupant: Bool
    var camera     : RoomCamera
    var lean       : Float

    /// The status the light shows; it picks the light's pulse.
    var status: WorkerStatus

    init(
        status     : WorkerStatus,
        shape      : WorkerShape,
        hasOccupant: Bool,
        camera     : RoomCamera = .top,
        lean       : Float = 0
    ) {
        let light = status.light ?? (red: 0, green: 0, blue: 0)
        self.lightColor  = SIMD3(
            Float(light.red),
            Float(light.green),
            Float(light.blue)
        )
        self.strength    = Float(status.lightStrength)
        self.shape       = shape
        self.hasOccupant = hasOccupant
        self.camera      = camera
        self.lean        = lean
        self.status      = status
    }

    /// 1 when the worker's screen lights the room: a busy worker in its room, seen through the tilted
    /// camera; 0 otherwise.
    var screenStrength: Float {
        camera == .tilted && status == .busy && hasOccupant ? 1 : 0
    }

    /// 1 when the moon lights the room: a room that is off, seen through the tilted camera; 0 otherwise.
    var moonStrength: Float {
        camera == .tilted && status == .off ? 1 : 0
    }

    /// The uniforms as the shaders read them, for a room of `size` points drawn into a texture of
    /// `pixelWidth` pixels across.
    func packed(
        size      : CGSize,
        pixelWidth: Int
    ) -> Packed {
        let room        = Shape(
            size: size,
            lean: lean
        )
        let outline     = shape.outline
        let perspective = camera == .tilted ? RoomCamera.Perspective(
            size: size,
            lean: lean
        ) : nil
        return Packed(
            light  : SIMD4(lightColor, strength),
            outline: outline.packed,
            body   : SIMD4(
                Float(outline.dome),
                Float(outline.bottom),
                perspective == nil ? 0 : Float(RoomCamera.slab(of: outline)),
                hasOccupant ? 1 : 0
            ),
            room   : SIMD4(
                Float(size.width),
                Float(size.height),
                Float(size.width) / Float(max(1, pixelWidth)),
                Float(perspective?.fillet ?? 0)
            ),
            shape  : SIMD4(
                room.wallHeight,
                room.wallReach,
                room.sphereRadius,
                room.cornerRadius
            ),
            camera : perspective?.packed ?? .zero,
            stage  : SIMD4(
                room.bodyX,
                lean,
                0,
                0
            ),
            lights : SIMD4(
                screenStrength,
                moonStrength,
                0,
                0
            )
        )
    }

    /// Shape is a room's proportions in points, the one source for the shaders and the ray tracer's
    /// geometry. Every length follows the room's short side.
    struct Shape {
        /// The sphere's radius, as a share of the room's short side, with the worker at the centre and
        /// at the left: at the left it is larger, the rows' worker.
        static let centreSphereShare: Float = 0.2
        static let leftSphereShare  : Float = 0.235

        /// How far from the room's left wall the worker stands when the composition leans left, as a
        /// share of the room's short side.
        static let leftInset: Float = 0.5

        /// Where a room leaning left goes dark, in short sides right of the worker: its light and
        /// ambient fade over this range and are gone past it, and so does the light it spills.
        /// RoomLight.metal's `darkFrom` and `darkTo` hold the same range; the floor plan's kernels
        /// compile exactly as before only while the shader keeps it as constants.
        static let rightDark: ClosedRange<Float> = 1.0...2.3

        /// How high the walls rise from the floor.
        let wallHeight: Float

        /// How far a wall's curved face reaches into the room, seen from above.
        let wallReach: Float

        let sphereRadius: Float

        /// The radius of the room's rounded outline: 14 points for a room 104 points tall.
        let cornerRadius: Float

        /// Where the worker's centre shows across the room, `bodyX(in:lean:)`.
        let bodyX: Float

        init(
            size: CGSize,
            lean: Float = 0
        ) {
            let side = Float(min(size.width, size.height))
            wallHeight   = 0.18 * side
            wallReach    = 0.045 * side
            sphereRadius = (Self.centreSphereShare + (Self.leftSphereShare - Self.centreSphereShare) * lean) * side
            cornerRadius = 14.0 / 104.0 * side
            bodyX        = Float(Self.bodyX(
                in  : size,
                lean: lean
            ))
        }

        /// Where the worker's centre shows across a room of `size` whose composition leans `lean`, in
        /// points from its left edge: the middle, or `leftInset` of the short side in at `lean` 1. The
        /// tilted camera stands the body where it shows there (`RoomCamera.Perspective.bodyX`).
        static func bodyX(
            in size: CGSize,
            lean   : Float
        ) -> CGFloat {
            let half = size.width / 2
            return half + (CGFloat(leftInset) * min(size.width, size.height) - half) * CGFloat(lean)
        }
    }

    /// Packed matches `RoomLightUniforms` in RoomLight.metal field for field: eight `float4`s, 128
    /// bytes, so no member needs padding on either side.
    struct Packed {
        /// sRGB colour, and the strength in `w`.
        var light: SIMD4<Float>

        /// The body's outline, `ShapeOutline.packed`, in sphere radii.
        var outline: SIMD4<Float>

        /// The body's dome height, lowest point and, standing in the tilted view, its slab
        /// (`RoomCamera.slab`), in sphere radii, and 1 in `w` when the worker is in the room.
        var body: SIMD4<Float>

        /// Room width and height in points, points per pixel, and the tilted room's cove radius in
        /// points, zero from above.
        var room: SIMD4<Float>

        /// `Shape`: wall height, wall reach, sphere radius and corner radius, in points.
        var shape: SIMD4<Float>

        /// The tilted camera, `RoomCamera.Perspective.packed`, or zero from above.
        var camera: SIMD4<Float>

        /// Where the worker stands across the room in the scene, in points from its left wall, and in
        /// `y` the composition's lean; the shaders read them only when the lean is above zero.
        var stage: SIMD4<Float>

        /// `screenStrength` and `moonStrength`.
        var lights: SIMD4<Float>
    }
}
