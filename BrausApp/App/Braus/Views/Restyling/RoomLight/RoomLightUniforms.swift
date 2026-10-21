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
/// (`moonStrength`). The worker at the top of its conversation is lit from its name's capsule below
/// instead of a screen (`capsuleLight`).
///
/// At `lean` 0 the worker stands at the room's centre under its lamp, with the pool around it, as on
/// the floor plan. At 1, as in the rows, it stands larger at the left, the lamp above it and a little
/// further left, and the pool spreads from it toward the right, fading into the room's darker right
/// side; values between are the way from one to the other while a row reshapes.
///
/// `pose` moves the standing body a little away from rest, for the frames that bake its motion
/// (`RoomBodyMotion`); a room itself always shows it at rest.
nonisolated struct RoomLightUniforms: Equatable {
    var lightColor : SIMD3<Float>
    var strength   : Float
    var shape      : WorkerShape
    var hasOccupant: Bool
    var camera     : RoomCamera
    var lean       : Float
    var pose       = Pose.rest

    /// The status the light shows; it picks the light's pulse.
    var status: WorkerStatus

    /// The light of the name's capsule under the worker at the top of its conversation (`HeroLight`):
    /// sRGB colour, and its strength in `w`; zero where there is none. Seen through the tilted camera it
    /// stands low in front of the worker, facing it, in the screen's place, and holds still.
    var capsuleLight: SIMD4<Float>

    init(
        status      : WorkerStatus,
        shape       : WorkerShape,
        hasOccupant : Bool,
        camera      : RoomCamera = .top,
        lean        : Float = 0,
        capsuleLight: SIMD4<Float> = .zero
    ) {
        let light = status.light ?? (red: 0, green: 0, blue: 0)
        self.lightColor   = SIMD3(
            Float(light.red),
            Float(light.green),
            Float(light.blue)
        )
        self.strength     = Float(status.lightStrength)
        self.shape        = shape
        self.hasOccupant  = hasOccupant
        self.camera       = camera
        self.lean         = lean
        self.status       = status
        self.capsuleLight = capsuleLight
    }

    /// 1 when the worker's screen lights the room: a busy worker in its room, seen through the tilted
    /// camera and not lit by a capsule; 0 otherwise.
    var screenStrength: Float {
        camera == .tilted && status == .busy && hasOccupant && capsuleStrength == 0 ? 1 : 0
    }

    /// The capsule's strength where it lights the worker: in its room, seen through the tilted camera;
    /// 0 otherwise.
    var capsuleStrength: Float {
        camera == .tilted && hasOccupant ? capsuleLight.w : 0
    }

    /// Whether a light low in front of the worker, its screen or the capsule, writes the third image.
    var hasFrontLight: Bool {
        screenStrength > 0 || capsuleStrength > 0
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
                pose.tilt,
                pose.hop
            ),
            lights : SIMD4(
                screenStrength,
                moonStrength,
                pose.slide,
                pose.scale
            ),
            capsule: SIMD4(
                capsuleLight.x,
                capsuleLight.y,
                capsuleLight.z,
                capsuleStrength
            ),
            posture: SIMD4(
                pose.shift,
                pose.stretch,
                pose.lean,
                0
            )
        )
    }

    /// Pose is how far the standing body has moved from rest, seen through the tilted camera, all about
    /// the floor's point under it: its size against rest (`scale`), taller and narrower by `stretch`,
    /// keeping its volume, leaning toward the camera by `lean` and turned with its top toward the right
    /// by `tilt`, in radians, then moved across (`shift`), toward the camera (`slide`) and up (`hop`),
    /// in points. The view from above shows the body at rest.
    struct Pose: Hashable {
        var tilt   : Float = 0
        var hop    : Float = 0
        var slide  : Float = 0
        var scale  : Float = 1
        var shift  : Float = 0
        var stretch: Float = 1
        var lean   : Float = 0

        static let rest = Pose()

        /// Where `point` of the body at rest shows in this pose, `foot` the floor's point under it;
        /// at rest the point itself, to the last bit.
        func moved(
            _ point: SIMD3<Double>,
            foot   : SIMD3<Double>
        ) -> SIMD3<Double> {
            guard self != .rest else { return point }
            var offset = (point - foot) * Double(scale)
            let across = 1 / Double(stretch).squareRoot()
            offset = SIMD3(
                offset.x * across,
                offset.y * across,
                offset.z * Double(stretch)
            )
            let leaning = (cosine: Double(cos(lean)), sine: Double(sin(lean)))
            offset = SIMD3(
                offset.x,
                offset.y * leaning.cosine + offset.z * leaning.sine,
                offset.z * leaning.cosine - offset.y * leaning.sine
            )
            let turning = (cosine: Double(cos(tilt)), sine: Double(sin(tilt)))
            return foot + SIMD3(
                offset.x * turning.cosine + offset.z * turning.sine + Double(shift),
                offset.y + Double(slide),
                offset.z * turning.cosine - offset.x * turning.sine + Double(hop)
            )
        }
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

    /// Packed matches `RoomLightUniforms` in RoomLight.metal field for field: ten `float4`s, 160
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
        /// `y` the composition's lean; the shaders read them only when the lean is above zero. In `z`
        /// and `w` the pose's tilt and hop, which only the tilted view reads.
        var stage: SIMD4<Float>

        /// `screenStrength` and `moonStrength`, and in `z` and `w` the pose's slide and scale.
        var lights: SIMD4<Float>

        /// The capsule's sRGB colour, and `capsuleStrength` in `w`.
        var capsule: SIMD4<Float>

        /// The pose's shift across, its stretch, 1 at rest, and its lean toward the camera.
        var posture: SIMD4<Float>
    }
}
