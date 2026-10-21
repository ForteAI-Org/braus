//
//  PrecomputedRoomRenderer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Metal

/// PrecomputedRoomRenderer lights a room on GPUs without hardware ray tracing.
///
/// One compute pass per change evaluates the scene of RoomLight.metal analytically: the lamp's
/// elliptical pool on floor and walls, the light they bounce to each other, the sphere's soft
/// contact shadow as the share of the lamp it hides, and the sphere's metal with the lamp's soft
/// reflection and a smooth sheen of the pool and the floor toward the walls; the ray tracer reflects
/// the room itself. The finished frames stay on screen with no further GPU work. A room seen through
/// the tilted camera has its own kernel, which casts the camera's rays into the same scene, and a room
/// leaning left its own pair (`RoomKernels`).
final class PrecomputedRoomRenderer: RoomRenderer {
    let commandQueue   : MTLCommandQueue
    let resolvePipeline: MTLComputePipelineState

    private let kernels: RoomKernels

    /// Fails when the device gives no queue or a kernel cannot be loaded.
    init?(device: MTLDevice) {
        guard
            let queue   = device.makeCommandQueue(),
            let kernels = RoomKernels(
                verb: "precompute",
                load: { name in
                    Self.pipeline(
                        named : name,
                        device: device
                    )
                }
            ),
            let resolve = Self.pipeline(
                named : "resolveRoom",
                device: device
            )
        else { return nil }
        commandQueue    = queue
        self.kernels    = kernels
        resolvePipeline = resolve
    }

    func encodeImages(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        base         : MTLTexture,
        light        : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        dispatch(
            kernels.pipeline(for: uniforms),
            uniforms: uniforms,
            size    : size,
            base    : base,
            light   : light,
            encoder : encoder
        )
    }
}
