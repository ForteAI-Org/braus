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
/// falloff on floor and walls, the light they bounce to each other, the sphere's soft contact shadow
/// as the share of the lamp it hides, and the sphere's body with the room reflected on its rim. The
/// finished image stays on screen with no further GPU work.
final class PrecomputedRoomRenderer: RoomRenderer {
    let commandQueue: MTLCommandQueue

    private let pipeline: MTLComputePipelineState

    /// Fails when the device gives no queue or the kernel cannot be loaded.
    init?(device: MTLDevice) {
        guard
            let queue    = device.makeCommandQueue(),
            let pipeline = Self.pipeline(
                named : "precomputeRoom",
                device: device
            )
        else { return nil }
        commandQueue  = queue
        self.pipeline = pipeline
    }

    func encode(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        into texture : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        dispatch(
            pipeline,
            uniforms: uniforms,
            size    : size,
            into    : texture,
            encoder : encoder
        )
    }
}
