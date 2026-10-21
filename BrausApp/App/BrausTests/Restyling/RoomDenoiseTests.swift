//
//  RoomDenoiseTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import MetalFX
import Testing
import simd
@testable import Braus

@Suite("RoomDenoise", .serialized)
@MainActor
struct RoomDenoiseTests {

    /// Whether this Mac's GPU takes MetalFX's denoised upscaler.
    nonisolated private static var hasDenoiser: Bool {
        guard #available(macOS 26, *), let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device) && device.supportsRaytracing
    }

    @Test("The denoiser is used only where MetalFX supports it, unless BRAUS_ROOM_DENOISE is off")
    func choice() throws {
        #expect(RayTracedRoomRenderer.denoises(isSupported: true, override: nil))
        #expect(RayTracedRoomRenderer.denoises(isSupported: true, override: "on"))
        #expect(!RayTracedRoomRenderer.denoises(isSupported: true, override: "off"))
        #expect(!RayTracedRoomRenderer.denoises(isSupported: false, override: nil))
        #expect(!RayTracedRoomRenderer.denoises(isSupported: false, override: "on"))

        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(RayTracedRoomRenderer.denoises(for: device, override: nil) == Self.hasDenoiser)
        #expect(!RayTracedRoomRenderer.denoises(for: device, override: "off"))
    }

    @Test(
        "Without the denoiser, and from above, the ray tracer accumulates its frames as before",
        .enabled(if: hasDenoiser)
    )
    func fallback() throws {
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let disabled = try #require(RayTracedRoomRenderer(device: device, denoises: false))
        #expect(!disabled.denoises)
        try Self.render(Self.room(.tilted), with: disabled, device: device)
        #expect(disabled.denoisedFrames == 0)

        let enabled = try #require(RayTracedRoomRenderer(device: device, denoises: true))
        try Self.render(Self.room(.top), with: enabled, device: device)
        #expect(enabled.denoisedFrames == 0)
    }

    @Test("The guides the tracer writes have the formats, sizes and usage the denoiser's scalers expect", .enabled(if: hasDenoiser))
    func guidesMatchTheScalers() throws {
        guard #available(macOS 26, *) else { return }
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let denoiser = try #require(RoomDenoiser(device: device, width: 508, height: 416))
        let inputs   = denoiser.inputs
        func input(_ which: RoomDenoiser.Input) -> MTLTexture { inputs[which.rawValue] }
        #expect(inputs.count == RoomDenoiser.Input.allCases.count)
        for texture in inputs {
            #expect(texture.width == denoiser.inputWidth && texture.height == denoiser.inputHeight)
        }
        #expect(denoiser.inputWidth == 381 && denoiser.inputHeight == 312)
        for scaler in denoiser.scalers {
            let pairs: [(MTLTexture, MTLPixelFormat, MTLTextureUsage)] = [
                (input(.base), scaler.colorTextureFormat, scaler.colorTextureUsage),
                (input(.light), scaler.colorTextureFormat, scaler.colorTextureUsage),
                (input(.depth), scaler.depthTextureFormat, scaler.depthTextureUsage),
                (input(.normal), scaler.normalTextureFormat, scaler.normalTextureUsage),
                (input(.diffuseAlbedo), scaler.diffuseAlbedoTextureFormat, scaler.diffuseAlbedoTextureUsage),
                (input(.specularAlbedo), scaler.specularAlbedoTextureFormat, scaler.specularAlbedoTextureUsage),
                (input(.roughness), scaler.roughnessTextureFormat, scaler.roughnessTextureUsage),
                (try #require(scaler.motionTexture), scaler.motionTextureFormat, scaler.motionTextureUsage),
            ]
            for (texture, format, usage) in pairs {
                #expect(texture.pixelFormat == format, "\(texture.pixelFormat.rawValue) against \(format.rawValue)")
                #expect(texture.usage.isSuperset(of: usage))
            }
            #expect(scaler.inputWidth == denoiser.inputWidth && scaler.inputHeight == denoiser.inputHeight)
            #expect(scaler.outputWidth == 508 && scaler.outputHeight == 416)
            // The renderers' linear images, which the scalers write.
            #expect(scaler.outputTextureFormat == .rgba16Float)
            #expect(MTLTextureUsage([.shaderRead, .shaderWrite, .renderTarget]).isSuperset(of: scaler.outputTextureUsage))
        }
        // `BurstFrame` in RoomLight.metal: a float4x4, two float2 and a uint, padded to 96 bytes.
        #expect(MemoryLayout<RoomDenoiser.Frame>.stride == 96)
    }

    @Test("The camera's matrices put the window's corners at the clip space's, at the depth of the window")
    func cameraMatrices() {
        for size in [CGSize(width: 254, height: 208), CGSize(width: 127, height: 104), CGSize(width: 260, height: 104)] {
            let perspective = RoomCamera.Perspective(size: size)
            let clip        = perspective.viewToClip(near: 1) * perspective.worldToView
            let corners: [(SIMD3<Double>, SIMD2<Float>)] = [
                (SIMD3(0, 0, perspective.wallTop), SIMD2(-1, 1)),
                (SIMD3(size.width, 0, perspective.wallTop), SIMD2(1, 1)),
                (SIMD3(0, perspective.depth, 0), SIMD2(-1, -1)),
                (SIMD3(size.width, perspective.depth, 0), SIMD2(1, -1)),
            ]
            for (point, corner) in corners {
                let projected = clip * SIMD4(SIMD3<Float>(point), 1)
                let shown     = SIMD2(projected.x, projected.y) / projected.w
                #expect(simd_distance(shown, corner) < 1e-4, "\(size): \(point) shows at \(shown)")
                #expect(abs(projected.z / projected.w - 1 / Float(perspective.focal)) < 1e-6)
            }
        }
    }

    @Test("A denoised render traces one burst, and the body casts its shadow toward the camera", .enabled(if: hasDenoiser))
    func oneBurstWithAShadow() throws {
        guard #available(macOS 26, *) else { return }
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(RayTracedRoomRenderer(device: device, denoises: true))
        let size     = CGSize(width: 254, height: 208)
        let occupied = try Self.render(Self.room(.tilted), with: renderer, device: device, size: size)
        #expect(renderer.denoisedFrames == RoomDenoiser.burst)
        let empty = try Self.render(Self.room(.tilted, hasOccupant: false), with: renderer, device: device, size: size)
        #expect(renderer.denoisedFrames == 2 * RoomDenoiser.burst)

        // The floor just in front of the sphere, which the camera sees past it and the lamp behind it does not.
        let perspective = RoomCamera.Perspective(size: size)
        let radius      = Double(RoomLightUniforms.Shape(size: size).sphereRadius)
        let near        = perspective.project(SIMD3(size.width / 2, perspective.bodyDepth + 1.05 * radius, 0))
        let far         = perspective.project(SIMD3(size.width / 2, perspective.bodyDepth + 1.3 * radius, 0))
        let x           = Int(near.x)
        let rows        = Int(near.y.rounded(.up))...Int(far.y)
        let shaded      = rows.map { occupied.luma(x, $0) }.reduce(0, +)
        let lit         = rows.map { empty.luma(x, $0) }.reduce(0, +)
        #expect(shaded + 4 * Double(rows.count) < lit, "\(shaded) against \(lit)")
    }

    @Test("A still room stops rendering once its burst has converged")
    func stillRoomStops() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let window = NSWindow(
            contentRect: CGRect(
                x     : 0,
                y     : 0,
                width : 400,
                height: 300
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = RoomLightView(
            device  : device,
            uniforms: Self.room(.tilted),
            frame   : CGRect(
                x     : 0,
                y     : 0,
                width : 127,
                height: 104
            )
        )
        window.contentView?.addSubview(view)
        let deadline = ContinuousClock.now + .seconds(5)
        while view.renderCounts.full < 1 {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
        try await Task.sleep(for: .milliseconds(300))
        let settled = view.renderCounts
        try await Task.sleep(for: .seconds(1))
        #expect(view.renderCounts == settled)
    }

    private static func room(
        _ camera   : RoomCamera,
        hasOccupant: Bool = true
    ) -> RoomLightUniforms {
        RoomLightUniforms(
            status     : .busy,
            shape      : .circle,
            hasOccupant: hasOccupant,
            camera     : camera
        )
    }

    /// Pixels is a rendered room read back, in BGRA order.
    private struct Pixels {
        let width: Int
        let bytes: [UInt8]

        func luma(_ x: Int, _ y: Int) -> Double {
            let index = (y * width + x) * 4
            return 0.2126 * Double(bytes[index + 2]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index])
        }
    }

    /// Renders `uniforms` at one pixel per point into a room of `size` and reads it back.
    @discardableResult
    private static func render(
        _ uniforms   : RoomLightUniforms,
        with renderer: any RoomRenderer,
        device       : MTLDevice,
        size         : CGSize = CGSize(width: 127, height: 104)
    ) throws -> Pixels {
        let width      = Int(size.width)
        let height     = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width      : width,
            height     : height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        let texture       = try #require(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(
            uniforms,
            size         : size,
            into         : texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        var bytes = [UInt8](
            repeating: 0,
            count    : width * height * 4
        )
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from       : MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return Pixels(
            width: width,
            bytes: bytes
        )
    }
}
