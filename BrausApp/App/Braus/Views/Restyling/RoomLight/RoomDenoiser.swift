//
//  RoomDenoiser.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Metal
import MetalFX
import os
import simd

/// RoomDenoiser has MetalFX's denoised upscaler turn noisy ray-traced frames of a room, traced at a
/// reduced size, into the room's full-size base and light images.
///
/// It owns one scaler per image, so the light keeps its own image and pulses by its weight as it does
/// without the denoiser, and the frames' inputs: the noisy base and light, and the guides the tracer
/// writes noise-free from the scene, which both scalers read: depth, normals, diffuse and specular
/// albedo, roughness, and a motion that stays zero, since the room holds still. A render is a burst of
/// `burst` frames: the first resets the scalers' history, and each is jittered by the Halton sequence
/// and averages `samples` samples spread over each pixel. Then nothing more runs.
///
/// Measured on an M4 against a converged trace (Round 2 Task 1 report), one frame of 16 samples beats
/// 16 frames of one sample in error, grain and cost: the scalers' cost is per frame, and they do best
/// with clean input.
///
/// Creating a denoiser compiles and allocates on the calling thread, 0.1 seconds per size and close to
/// a second the first time, so the rooms of one size share one: `borrow` hands out an idle denoiser,
/// and the borrower gives it back with `giveBack` once its command buffer has completed, so no two
/// bursts ever share a history.
@available(macOS 26, *)
final class RoomDenoiser {

    /// Frames per burst.
    static let burst = 1

    /// Samples each frame averages per pixel before the denoiser takes it.
    static let samples = 16

    /// The traced size against the full size, per side, before the device's limits: at 0.6 the
    /// denoiser left blotches in a flat contact shadow.
    static let inputScale: Float = 0.75

    /// Input is one image the tracer writes per frame; its raw value is its texture index in
    /// RoomLight.metal's `traceTiltedRoomFrame`.
    enum Input: Int, CaseIterable {
        case base
        case light
        case depth
        case normal
        case diffuseAlbedo
        case specularAlbedo
        case roughness

        var pixelFormat: MTLPixelFormat {
            switch self {
            case .base, .light, .normal, .diffuseAlbedo, .specularAlbedo: .rgba16Float
            case .depth                                                 : .r32Float
            case .roughness                                             : .r16Float
            }
        }
    }

    /// Frame matches `BurstFrame` in RoomLight.metal: the transform from scene points to the clip
    /// space of the depth, the room's points per traced pixel across and down, the frame's sub-pixel
    /// jitter in traced pixels, its index in the burst, and the samples it averages per pixel.
    struct Frame {
        var clip          : simd_float4x4
        var pointsPerPixel: SIMD2<Float>
        var jitter        : SIMD2<Float>
        var index         : UInt32
        var samples       : UInt32
    }

    static let motionFormat = MTLPixelFormat.rg16Float
    static let outputFormat = MTLPixelFormat.rgba16Float

    let device      : MTLDevice
    let width       : Int
    let height      : Int
    let inputWidth  : Int
    let inputHeight : Int

    /// The tracer's images for one frame, indexed by `Input`, at the input size.
    let inputs: [MTLTexture]

    /// The scalers of the base and the light image.
    let scalers: [any MTLFXTemporalDenoisedScaler]

    /// Idle denoisers, the latest given back last. A few are kept, so the sizes in use stay ready
    /// while the sizes a resize passed through are let go.
    private static var idle: [RoomDenoiser] = []
    private static let idleLimit = 4

    private static let logger = Logger(
        subsystem: "dev.forte.Braus",
        category : "RoomLight"
    )

    /// Fails, with the failure logged, when the device makes no scaler or texture for this size.
    init?(
        device    : MTLDevice,
        width     : Int,
        height    : Int,
        inputScale: Float = RoomDenoiser.inputScale
    ) {
        // The device's limits are the full size against the traced one.
        let scale = min(
            max(inputScale, 1 / MTLFXTemporalDenoisedScalerDescriptor.supportedInputContentMaxScale(device: device)),
            1 / MTLFXTemporalDenoisedScalerDescriptor.supportedInputContentMinScale(device: device)
        )
        let inputWidth  = max(1, Int((Float(width) * scale).rounded(.up)))
        let inputHeight = max(1, Int((Float(height) * scale).rounded(.up)))
        let descriptor  = MTLFXTemporalDenoisedScalerDescriptor()
        descriptor.colorTextureFormat          = Input.base.pixelFormat
        descriptor.depthTextureFormat          = Input.depth.pixelFormat
        descriptor.motionTextureFormat         = Self.motionFormat
        descriptor.diffuseAlbedoTextureFormat  = Input.diffuseAlbedo.pixelFormat
        descriptor.specularAlbedoTextureFormat = Input.specularAlbedo.pixelFormat
        descriptor.normalTextureFormat         = Input.normal.pixelFormat
        descriptor.roughnessTextureFormat      = Input.roughness.pixelFormat
        descriptor.outputTextureFormat         = Self.outputFormat
        descriptor.inputWidth                  = inputWidth
        descriptor.inputHeight                 = inputHeight
        descriptor.outputWidth                 = width
        descriptor.outputHeight                = height
        // The rooms are dim: at exposure 1 the denoiser smooths their shadows away.
        descriptor.isAutoExposureEnabled       = true
        // A burst follows at once; a scaler still compiling in the background made its GPU work time out.
        descriptor.requiresSynchronousInitialization = true
        let scalers = (0..<2).compactMap { _ in descriptor.makeTemporalDenoisedScaler(device: device) }
        let inputs  = Input.allCases.compactMap { input in
            Self.texture(
                input.pixelFormat,
                width : inputWidth,
                height: inputHeight,
                device: device
            )
        }
        guard
            scalers.count == 2,
            inputs.count == Input.allCases.count,
            let motion = Self.zeroMotion(
                width : inputWidth,
                height: inputHeight,
                device: device
            )
        else {
            Self.logger.error("No room denoiser for \(width, privacy: .public)×\(height, privacy: .public) pixels")
            return nil
        }
        for scaler in scalers {
            scaler.depthTexture          = inputs[Input.depth.rawValue]
            scaler.normalTexture         = inputs[Input.normal.rawValue]
            scaler.diffuseAlbedoTexture  = inputs[Input.diffuseAlbedo.rawValue]
            scaler.specularAlbedoTexture = inputs[Input.specularAlbedo.rawValue]
            scaler.roughnessTexture      = inputs[Input.roughness.rawValue]
            scaler.motionTexture         = motion
        }
        self.device      = device
        self.width       = width
        self.height      = height
        self.inputWidth  = inputWidth
        self.inputHeight = inputHeight
        self.inputs      = inputs
        self.scalers     = scalers
    }

    /// An idle denoiser for images of `width` by `height` pixels on `device`, or a new one.
    static func borrow(
        device: MTLDevice,
        width : Int,
        height: Int
    ) -> RoomDenoiser? {
        let index = idle.lastIndex { denoiser in
            denoiser.device.registryID == device.registryID && denoiser.width == width && denoiser.height == height
        }
        guard let index else {
            return RoomDenoiser(
                device: device,
                width : width,
                height: height
            )
        }
        return idle.remove(at: index)
    }

    /// Makes the denoiser available again. Called once the command buffer of its burst has completed.
    func giveBack() {
        Self.idle.append(self)
        if Self.idle.count > Self.idleLimit {
            Self.idle.removeFirst()
        }
    }

    /// Encodes the scalers for frame `index` of a burst, after the tracer has written `inputs`, into
    /// `base` and `light`: private `outputFormat` textures of the full size. `camera` sees the scene the
    /// frame's depth was written for.
    func encode(
        frame index  : Int,
        camera       : RoomCamera.Perspective,
        base         : MTLTexture,
        light        : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        // MetalFX takes the offset from each sample back to its pixel's centre.
        let jitter = -Self.jitter(index)
        for (scaler, images) in zip(scalers, [(Input.base, base), (.light, light)]) {
            scaler.colorTexture       = inputs[images.0.rawValue]
            scaler.outputTexture      = images.1
            scaler.jitterOffsetX      = jitter.x
            scaler.jitterOffsetY      = jitter.y
            scaler.shouldResetHistory = index == 0
            scaler.worldToViewMatrix  = camera.worldToView
            scaler.viewToClipMatrix   = camera.viewToClip(near: Self.near)
            scaler.encode(commandBuffer: commandBuffer)
        }
    }

    /// Frame `index` of a burst for a room seen through `camera`, for the tracer, averaging `samples`
    /// samples per pixel.
    func frame(
        _ index: Int,
        samples: Int = RoomDenoiser.samples,
        camera : RoomCamera.Perspective
    ) -> Frame {
        Frame(
            clip          : camera.viewToClip(near: Self.near) * camera.worldToView,
            pointsPerPixel: SIMD2(
                Float(camera.size.width) / Float(inputWidth),
                Float(camera.size.height) / Float(inputHeight)
            ),
            jitter        : Self.jitter(index),
            index         : UInt32(index),
            samples       : UInt32(samples)
        )
    }

    /// Frame `index`'s sub-pixel offset of its samples from the traced pixels' centres, in traced
    /// pixels: the Halton sequence in bases 2 and 3, centred.
    static func jitter(_ index: Int) -> SIMD2<Float> {
        SIMD2(
            halton(index + 1, base: 2),
            halton(index + 1, base: 3)
        ) - 0.5
    }

    /// The depth's nearest distance from the eye, in points; nothing in a room comes closer.
    private static let near: Float = 1

    private static func halton(
        _ index: Int,
        base   : Int
    ) -> Float {
        var result   : Float = 0
        var fraction : Float = 1
        var remaining        = index
        while remaining > 0 {
            fraction  /= Float(base)
            result    += fraction * Float(remaining % base)
            remaining /= base
        }
        return result
    }

    /// A texture the tracer writes and the scalers read, private to the GPU.
    private static func texture(
        _ format: MTLPixelFormat,
        width   : Int,
        height  : Int,
        device  : MTLDevice
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width      : width,
            height     : height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// The motion of every pixel, zero: a room renders only while it holds still.
    private static func zeroMotion(
        width : Int,
        height: Int,
        device: MTLDevice
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: motionFormat,
            width      : width,
            height     : height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = width * 4
        let zeros       = [UInt8](
            repeating: 0,
            count    : bytesPerRow * height
        )
        texture.replace(
            region     : MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes  : zeros,
            bytesPerRow: bytesPerRow
        )
        return texture
    }
}
