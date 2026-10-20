//
//  RoomRenderer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Foundation
import Metal
import QuartzCore
import os

/// RoomRenderer lights a room with its worker into textures, once per change.
///
/// A renderer writes two linear images: the room without its worker's light, and the light alone.
/// Each target then receives their sum with the light at its own weight, tone mapped once; the view
/// uses the weights to play the light's pulse as a sequence of finished frames. Nothing is left
/// running, so a room at rest costs only compositing.
protocol RoomRenderer: AnyObject {

    /// The queue the renderer's command buffers come from.
    var commandQueue: MTLCommandQueue { get }

    /// The kernel that adds the two images and tone maps them.
    var resolvePipeline: MTLComputePipelineState { get }

    /// Encodes the room of `size` points into two linear `rgba16Float` images of the same pixel
    /// size: `base` without the worker's light, `light` the light alone.
    func encodeImages(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        base         : MTLTexture,
        light        : MTLTexture,
        commandBuffer: MTLCommandBuffer
    )

    /// Draws the room with its light at full strength into `drawable` and presents it.
    func render(
        _ uniforms   : RoomLightUniforms,
        into drawable: CAMetalDrawable,
        size         : CGSize
    )
}

/// The kernels whose loading failed and was logged, so each is logged once.
private var loggedKernelFailures: Set<String> = []

/// The compiled kernels, by device and kernel name, shared by every room: the library is loaded and
/// each pipeline built once per device.
private var loadedPipelines: [String: MTLComputePipelineState] = [:]
private var loadedLibraries: [UInt64: MTLLibrary] = [:]

private let logger = Logger(
    subsystem: "dev.forte.Braus",
    category : "RoomLight"
)

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

    /// Encodes the room with its light at full strength into `texture`, a writable `bgra8Unorm`
    /// texture whose pixels cover the room; the caller commits `commandBuffer`.
    func encode(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        into texture : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        encode(
            uniforms,
            size         : size,
            into         : [(texture, 1)],
            commandBuffer: commandBuffer
        )
    }

    /// Encodes the room once and resolves it into every target with the light at its weight. The
    /// targets are writable `bgra8Unorm` textures of one pixel size.
    func encode(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        into targets : [(texture: MTLTexture, weight: Float)],
        commandBuffer: MTLCommandBuffer
    ) {
        guard
            let first = targets.first?.texture,
            let base  = Self.linearImage(like: first),
            let light = Self.linearImage(like: first)
        else { return }
        encodeImages(
            uniforms,
            size         : size,
            base         : base,
            light        : light,
            commandBuffer: commandBuffer
        )
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(
            base,
            index: 0
        )
        encoder.setTexture(
            light,
            index: 1
        )
        for target in targets {
            var weight = target.weight
            encoder.setTexture(
                target.texture,
                index: 2
            )
            encoder.setBytes(
                &weight,
                length: MemoryLayout<Float>.size,
                index : 0
            )
            Self.dispatchPerPixel(
                of     : target.texture,
                encoder: encoder
            )
        }
        encoder.endEncoding()
    }

    /// The compute pipeline of the kernel `name` in RoomLight.metal, built once per device, or nil
    /// when the library or the kernel cannot be loaded; the first failure of each kernel is logged.
    static func pipeline(
        named name: String,
        device    : MTLDevice
    ) -> MTLComputePipelineState? {
        let key = "\(device.registryID)/\(name)"
        if let pipeline = loadedPipelines[key] { return pipeline }
        do {
            let library = try loadedLibraries[device.registryID]
                ?? device.makeDefaultLibrary(bundle: Bundle(for: Self.self))
            loadedLibraries[device.registryID] = library
            guard let function = library.makeFunction(name: name) else {
                throw CocoaError(.featureUnsupported)
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            loadedPipelines[key] = pipeline
            return pipeline
        } catch {
            if loggedKernelFailures.insert(name).inserted {
                logger.error("Room light kernel \(name, privacy: .public) did not load: \(error, privacy: .public)")
            }
            return nil
        }
    }

    /// Encodes `pipeline` over every pixel of `base` with the room's uniforms in buffer 0
    /// and the two images in textures 0 and 1.
    func dispatch(
        _ pipeline   : MTLComputePipelineState,
        uniforms     : RoomLightUniforms,
        size         : CGSize,
        base         : MTLTexture,
        light        : MTLTexture,
        encoder      : MTLComputeCommandEncoder
    ) {
        var packed = uniforms.packed(
            size      : size,
            pixelWidth: base.width
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(
            base,
            index: 0
        )
        encoder.setTexture(
            light,
            index: 1
        )
        encoder.setBytes(
            &packed,
            length: MemoryLayout<RoomLightUniforms.Packed>.stride,
            index : 0
        )
        Self.dispatchPerPixel(
            of     : base,
            encoder: encoder
        )
        encoder.endEncoding()
    }

    private static func dispatchPerPixel(
        of texture: MTLTexture,
        encoder   : MTLComputeCommandEncoder
    ) {
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
    }

    /// A linear half-float image the size of `texture`, private to the GPU.
    private static func linearImage(like texture: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width      : texture.width,
            height     : texture.height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return texture.device.makeTexture(descriptor: descriptor)
    }
}
