//
//  LightingPath.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Metal

/// LightingPath is how a room's light is computed: traced on GPUs with hardware ray tracing,
/// evaluated analytically on the others.
///
/// Hardware ray tracing means Apple GPU family 9, Apple silicon M3 and later. Metal also reports
/// `supportsRaytracing` on M1 and M2 and on Intel and AMD GPUs, where rays are traced in software:
/// those Macs always get the precomputed light.
nonisolated enum LightingPath: String, Sendable {
    case rayTraced = "raytraced"
    case precomputed

    /// The path for a GPU described by its capabilities. `override` is the value of
    /// `BRAUS_ROOM_LIGHT`; it can force the precomputed path, never ray tracing on a GPU without
    /// the hardware for it.
    static func choose(
        isAppleFamily9    : Bool,
        supportsRaytracing: Bool,
        override          : String?
    ) -> LightingPath {
        guard isAppleFamily9 && supportsRaytracing else { return .precomputed }
        return override.flatMap(LightingPath.init(rawValue:)) ?? .rayTraced
    }

    /// The path for `device`.
    static func choose(
        for device: MTLDevice,
        override  : String?
    ) -> LightingPath {
        choose(
            isAppleFamily9    : device.supportsFamily(.apple9),
            supportsRaytracing: device.supportsRaytracing,
            override          : override
        )
    }
}
