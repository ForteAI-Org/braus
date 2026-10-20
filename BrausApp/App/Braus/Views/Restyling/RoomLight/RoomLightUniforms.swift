//
//  RoomLightUniforms.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit

/// RoomLightUniforms is what a room's light depends on: the worker's status light, its tint and
/// whether the worker is in the room.
///
/// Colours are sRGB components in 0...1; the shaders linearise them.
nonisolated struct RoomLightUniforms: Equatable {
    var lightColor : SIMD3<Float>
    var strength   : Float
    var tint       : SIMD3<Float>
    var hasOccupant: Bool

    /// The status the light shows; it picks the light's pulse.
    var status: WorkerStatus

    init(
        status     : WorkerStatus,
        tint       : NSColor,
        hasOccupant: Bool
    ) {
        let light = status.light ?? (red: 0, green: 0, blue: 0)
        let srgb  = tint.usingColorSpace(.sRGB) ?? NSColor(white: 0.5, alpha: 1)
        self.lightColor  = SIMD3(
            Float(light.red),
            Float(light.green),
            Float(light.blue)
        )
        self.strength    = Float(status.lightStrength)
        self.tint        = SIMD3(
            Float(srgb.redComponent),
            Float(srgb.greenComponent),
            Float(srgb.blueComponent)
        )
        self.hasOccupant = hasOccupant
        self.status      = status
    }

    /// The uniforms as the shaders read them, for a room of `size` points drawn into a texture of
    /// `pixelWidth` pixels across.
    func packed(
        size      : CGSize,
        pixelWidth: Int
    ) -> Packed {
        let shape = Shape(size: size)
        return Packed(
            light: SIMD4(lightColor, strength),
            tint : SIMD4(tint, hasOccupant ? 1 : 0),
            room : SIMD4(
                Float(size.width),
                Float(size.height),
                Float(size.width) / Float(max(1, pixelWidth)),
                0
            ),
            shape: SIMD4(
                shape.wallHeight,
                shape.wallReach,
                shape.sphereRadius,
                shape.cornerRadius
            )
        )
    }

    /// Shape is a room's proportions in points, the one source for the shaders and the ray tracer's
    /// geometry. Every length follows the room's short side.
    struct Shape {
        /// How high the walls rise from the floor.
        let wallHeight: Float

        /// How far a wall's curved face reaches into the room, seen from above.
        let wallReach: Float

        let sphereRadius: Float

        /// The radius of the room's rounded outline: 14 points for a room 104 points tall.
        let cornerRadius: Float

        init(size: CGSize) {
            let side = Float(min(size.width, size.height))
            wallHeight   = 0.18 * side
            wallReach    = 0.045 * side
            sphereRadius = 0.17 * side
            cornerRadius = 14.0 / 104.0 * side
        }
    }

    /// Packed matches `RoomLightUniforms` in RoomLight.metal field for field: four `float4`s, 64
    /// bytes, so no member needs padding on either side.
    struct Packed {
        /// sRGB colour, and the strength in `w`.
        var light: SIMD4<Float>

        /// sRGB tint, and 1 in `w` when the worker is in the room.
        var tint: SIMD4<Float>

        /// Room width and height in points, points per pixel, and an unused lane.
        var room: SIMD4<Float>

        /// `Shape`: wall height, wall reach, sphere radius and corner radius, in points.
        var shape: SIMD4<Float>
    }
}
