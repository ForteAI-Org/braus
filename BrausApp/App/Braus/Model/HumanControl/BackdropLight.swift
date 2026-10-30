//
//  BackdropLight.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import Foundation
import simd

/// BackdropLight turns what lies behind the overlay on the person's screen, the wallpaper or an app,
/// into the light that falls on the worker's front: the light `HouseWorkerPortrait` takes from below
/// (`capsuleLight`), the backdrop's colour toward warm white, stronger the brighter the backdrop.
///
/// The backdrop is sampled every `interval` seconds as a few pixels, and the worker is lit again only
/// when the light `differs`: a still backdrop costs one tiny capture per interval and no render.
nonisolated enum BackdropLight {

    /// Seconds between two samples of the backdrop.
    static let interval: Double = 4

    /// The warm white the capsule's light starts from (`HeroLight`), which the backdrop's colour tints.
    private static let warm = SIMD3<Float>(1, 0.95, 0.86)

    /// The mean colour of `pixels`, RGBA bytes in sRGB, in 0...1; nil when there is no whole pixel.
    static func average(of pixels: [UInt8]) -> SIMD3<Float>? {
        let count = pixels.count / 4
        guard count > 0 else { return nil }
        var sum = SIMD3<Float>.zero
        for index in 0..<count {
            sum += SIMD3(
                Float(pixels[4 * index]),
                Float(pixels[4 * index + 1]),
                Float(pixels[4 * index + 2])
            )
        }
        return sum / Float(count * 255)
    }

    /// The light on the worker's front for a backdrop of mean colour `backdrop`: its hue at full
    /// brightness, half way to warm white, its strength from 0.2 on black to 0.8 on white, in steps so
    /// a backdrop that barely changes gives the same light.
    static func light(for backdrop: SIMD3<Float>) -> SIMD4<Float> {
        let clamped   = simd_clamp(backdrop, .zero, .one)
        let luminance = simd_dot(clamped, SIMD3(0.2126, 0.7152, 0.0722))
        let peak      = max(clamped.max(), 0.001)
        let tint      = simd_mix(clamped / peak, warm, SIMD3(repeating: 0.5))
        let step      = Float(1.0 / 32)
        return SIMD4(
            (tint / step).rounded(.toNearestOrAwayFromZero) * step,
            ((0.2 + 0.6 * luminance) / 0.05).rounded() * 0.05
        )
    }

    /// Whether `new` is far enough from `old` to light the worker again.
    static func differs(
        _ new: SIMD4<Float>,
        from old: SIMD4<Float>
    ) -> Bool {
        abs(new - old).max() > 0.07
    }
}
