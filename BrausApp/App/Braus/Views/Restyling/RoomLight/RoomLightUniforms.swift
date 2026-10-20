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

    /// The status the light shows; it picks the room's ambient motion.
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
        Packed(
            light: SIMD4(lightColor, strength),
            tint : SIMD4(tint, hasOccupant ? 1 : 0),
            room : SIMD4(
                Float(size.width),
                Float(size.height),
                Float(size.width) / Float(max(1, pixelWidth)),
                0
            )
        )
    }

    /// Packed matches `RoomLightUniforms` in RoomLight.metal field for field: three `float4`s, 48
    /// bytes, so no member needs padding on either side.
    struct Packed {
        /// sRGB colour, and the strength in `w`.
        var light: SIMD4<Float>

        /// sRGB tint, and 1 in `w` when the worker is in the room.
        var tint: SIMD4<Float>

        /// Room width and height in points, points per pixel, and an unused lane.
        var room: SIMD4<Float>
    }
}
