//
//  RoomRenderer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation
import Metal
import QuartzCore

/// RoomRenderer draws a room lit by its worker into a texture, once per change.
///
/// A render presents one finished image: nothing is left running, so a room at rest costs only
/// compositing.
protocol RoomRenderer: AnyObject {

    /// The queue the renderer's command buffers come from.
    var commandQueue: MTLCommandQueue { get }

    /// Encodes the room of `size` points into `texture`, a writable `bgra8Unorm` texture whose pixels
    /// cover the room; the caller commits `commandBuffer`.
    func encode(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        into texture : MTLTexture,
        commandBuffer: MTLCommandBuffer
    )

    /// Draws the room into `drawable` and presents it.
    func render(
        _ uniforms   : RoomLightUniforms,
        into drawable: CAMetalDrawable,
        size         : CGSize
    )
}

extension RoomRenderer {

    func render(
        _ uniforms   : RoomLightUniforms,
        into drawable: CAMetalDrawable,
        size         : CGSize
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encode(
            uniforms,
            size         : size,
            into         : drawable.texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The compute pipeline of the kernel `name` in RoomLight.metal, or nil when the library or the
    /// kernel cannot be loaded.
    static func pipeline(
        named name: String,
        device    : MTLDevice
    ) -> MTLComputePipelineState? {
        guard
            let library  = try? device.makeDefaultLibrary(bundle: Bundle(for: Self.self)),
            let function = library.makeFunction(name: name)
        else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    /// Encodes `pipeline` over every pixel of `texture` with the room's uniforms in buffer 0.
    func dispatch(
        _ pipeline   : MTLComputePipelineState,
        uniforms     : RoomLightUniforms,
        size         : CGSize,
        into texture : MTLTexture,
        encoder      : MTLComputeCommandEncoder
    ) {
        var packed = uniforms.packed(
            size      : size,
            pixelWidth: texture.width
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(
            texture,
            index: 0
        )
        encoder.setBytes(
            &packed,
            length: MemoryLayout<RoomLightUniforms.Packed>.stride,
            index : 0
        )
        encoder.dispatchThreads(
            MTLSize(
                width : texture.width,
                height: texture.height,
                depth : 1
            ),
            threadsPerThreadgroup: MTLSize(
                width : 8,
                height: 8,
                depth : 1
            )
        )
        encoder.endEncoding()
    }
}
