//
//  LightingPath.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation

/// LightingPath is how a room's light is computed: traced on GPUs with hardware ray tracing,
/// evaluated analytically on the others.
nonisolated enum LightingPath: String, Sendable {
    case rayTraced = "raytraced"
    case precomputed

    /// The path for a GPU that does or does not trace rays in hardware. `override` is the value of
    /// `BRAUS_ROOM_LIGHT`; it can force the precomputed path, never hardware the GPU lacks.
    static func choose(
        supportsRaytracing: Bool,
        override          : String?
    ) -> LightingPath {
        guard supportsRaytracing else { return .precomputed }
        return override.flatMap(LightingPath.init(rawValue:)) ?? .rayTraced
    }
}
