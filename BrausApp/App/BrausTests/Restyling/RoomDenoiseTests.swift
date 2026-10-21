//
//  RoomDenoiseTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import MetalFX
import Synchronization
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
    func guidesMatchTheScalers() async throws {
        guard #available(macOS 26, *) else { return }
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let prepared = await Task.detached {
            RoomDenoiser(
                device: device,
                width : 512,
                height: 448
            )
        }.value
        let denoiser = try #require(prepared)
        let inputs   = denoiser.inputs
        func input(_ which: RoomDenoiser.Input) -> MTLTexture { inputs[which.rawValue] }
        #expect(inputs.count == RoomDenoiser.Input.allCases.count)
        for texture in inputs {
            #expect(texture.width == denoiser.inputWidth && texture.height == denoiser.inputHeight)
        }
        #expect(denoiser.inputWidth == 384 && denoiser.inputHeight == 336)
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
            #expect(scaler.outputWidth == 512 && scaler.outputHeight == 448)
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
    func oneBurstWithAShadow() async throws {
        guard #available(macOS 26, *) else { return }
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(RayTracedRoomRenderer(device: device, denoises: true))
        let size     = CGSize(width: 254, height: 208)
        defer { renderer.releaseDenoiser() }
        renderer.prepareDenoiser(
            pixelSize: size,
            camera   : .tilted
        )
        try await Self.until { renderer.denoisedPixelSize != nil }
        let occupied = try Self.render(Self.room(.tilted), with: renderer, device: device, size: size)
        #expect(renderer.denoisedFrames == RoomDenoiser.burst)
        try await Self.until { renderer.denoisedPixelSize != nil }
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
        let expectsDenoising = Self.hasDenoiser && view.path == .rayTraced
            && ProcessInfo.processInfo.environment["BRAUS_ROOM_DENOISE"] != "off"
        let deadline = ContinuousClock.now + .seconds(30)
        while view.renderCounts.full < 1 || (expectsDenoising && view.denoisedFrames == 0) {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
        try await Task.sleep(for: .milliseconds(300))
        let settled = view.renderCounts
        try await Task.sleep(for: .seconds(1))
        #expect(view.renderCounts == settled)
        if expectsDenoising { #expect(view.denoisedFrames == 1) }
    }

    @Test("Room sizes reuse 64-pixel buckets at both backing scales")
    func buckets() {
        guard #available(macOS 26, *) else { return }
        let examples = [
            (127, 104, 128, 128), (120, 92, 128, 128), (260, 104, 320, 128),
            (254, 208, 256, 256), (240, 184, 256, 192), (520, 208, 576, 256),
        ]
        for (width, height, outputWidth, outputHeight) in examples {
            let bucket = RoomDenoiserPool.Bucket(
                deviceID: 1,
                width   : width,
                height  : height
            )
            #expect(bucket.width == outputWidth)
            #expect(bucket.height == outputHeight)
        }
    }

    @Test("Creation leaves the main thread; cancellation and failed creation release the slot")
    func backgroundCreationAndCancellation() async throws {
        guard #available(macOS 26, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let started = Mutex(false)
        let gate = DispatchSemaphore(value: 0)
        let pool = RoomDenoiserPool(
            capacity: 1,
            create  : { _, _ in
                #expect(!Thread.isMainThread)
                started.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 5)
                return nil
            }
        )
        let request = pool.request(
            device : device,
            width  : 127,
            height : 104,
            onReady: { Issue.record("A failed scaler must not become ready") }
        )
        defer { gate.signal() }
        try await Self.until { started.withLock { $0 } }
        #expect(!request.isReady)
        #expect(request.borrow() == nil)
        #expect(pool.count == 1)
        request.cancel()
        #expect(pool.count == 1, "In-progress construction still consumes its slot")
        gate.signal()
        try await Self.until { pool.count == 0 }
    }

    @Test(
        "A pending room draws analytic shadows, then switches once its bucket is ready",
        .enabled(if: hasDenoiser)
    )
    func fallbackUntilReady() async throws {
        guard #available(macOS 26, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(RayTracedRoomRenderer(
            device  : device,
            denoises: true
        ))
        let analytic = try #require(RayTracedRoomRenderer(
            device  : device,
            denoises: false
        ))
        let size = CGSize(
            width : 191,
            height: 109
        )
        defer { renderer.releaseDenoiser() }
        var notifications = 0
        renderer.denoiserDidBecomeReady = { notifications += 1 }
        renderer.prepareDenoiser(
            pixelSize: size,
            camera   : .tilted
        )
        #expect(renderer.denoisedPixelSize == nil)
        let fallback = try Self.render(
            Self.room(.tilted),
            with  : renderer,
            device: device,
            size  : size
        )
        let reference = try Self.render(
            Self.room(.tilted),
            with  : analytic,
            device: device,
            size  : size
        )
        #expect(fallback.bytes == reference.bytes)
        #expect(renderer.denoisedFrames == 0)
        try await Self.until { renderer.denoisedPixelSize != nil }
        #expect(notifications == 1)
        try Self.render(
            Self.room(.tilted),
            with  : renderer,
            device: device,
            size  : size
        )
        #expect(renderer.denoisedFrames == RoomDenoiser.burst)
        try await Self.until { renderer.denoisedPixelSize != nil }
        #expect(notifications == 1, "Giving back a used scaler must not schedule another still frame")
    }

    @Test(
        "Buckets share one exclusive pair, retain GPU loans, and evict the least recently used pair",
        .enabled(if: hasDenoiser)
    )
    func reuseAndCap() async throws {
        guard #available(macOS 26, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = RoomDenoiserPool(capacity: 2)
        let first = pool.request(
            device : device,
            width  : 127,
            height : 104,
            onReady: {}
        )
        let same = pool.request(
            device : device,
            width  : 120,
            height : 92,
            onReady: {}
        )
        let second = pool.request(
            device : device,
            width  : 190,
            height : 104,
            onReady: {}
        )
        defer {
            first.cancel()
            same.cancel()
            second.cancel()
        }
        try await Self.until { first.isReady && second.isReady }
        #expect(pool.count == 2)
        let original = try #require(first.borrow())
        #expect(same.borrow() == nil, "The second room cannot overwrite a borrowed history")
        pool.giveBack(original)
        let reused = try #require(same.borrow())
        #expect(reused === original)
        pool.giveBack(reused)
        let newer = try #require(second.borrow())
        pool.giveBack(newer)
        let third = pool.request(
            device : device,
            width  : 255,
            height : 104,
            onReady: {}
        )
        defer { third.cancel() }
        try await Self.until { third.isReady }
        #expect(pool.count == 2)
        #expect(!first.isReady && second.isReady, "The oldest idle bucket was evicted")
        let held = try #require(third.borrow())
        third.cancel()
        #expect(pool.count == 2, "Cancellation cannot release an in-flight loan")
        pool.giveBack(held)
        #expect(pool.count == 1)
        first.cancel()
        same.cancel()
        second.cancel()
        #expect(pool.count == 0)
    }

    @Test(
        "Many pending sizes render immediately and every fallback and denoised submission completes",
        .enabled(if: hasDenoiser)
    )
    func stressPendingSizes() async throws {
        guard #available(macOS 26, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        var rooms: [(renderer: RayTracedRoomRenderer, size: CGSize)] = []
        defer { rooms.forEach { $0.renderer.releaseDenoiser() } }
        for index in 0..<12 {
            let renderer = try #require(RayTracedRoomRenderer(
                device  : device,
                denoises: true
            ))
            let size = CGSize(
                width : 97 + index * 64,
                height: 107
            )
            rooms.append((renderer, size))
            renderer.prepareDenoiser(
                pixelSize: size,
                camera   : .tilted
            )
            try Self.render(
                Self.room(.tilted),
                with  : renderer,
                device: device,
                size  : size
            )
            #expect(renderer.denoisedFrames == 0)
            #expect(RoomDenoiserPool.shared.count <= 6)
        }
        var remaining = Set(rooms.indices)
        let deadline = ContinuousClock.now + .seconds(60)
        while !remaining.isEmpty {
            try #require(ContinuousClock.now < deadline, "Pending rooms did not receive their denoisers")
            for index in remaining.sorted() {
                let room = rooms[index]
                guard room.renderer.denoisedPixelSize != nil else { continue }
                try Self.render(
                    Self.room(.tilted),
                    with  : room.renderer,
                    device: device,
                    size  : room.size
                )
                #expect(room.renderer.denoisedFrames == RoomDenoiser.burst)
                remaining.remove(index)
            }
            #expect(RoomDenoiserPool.shared.count <= 6)
            try await Task.sleep(for: .milliseconds(4))
        }
        // A final ordinary submission also has to complete after all MetalFX work.
        let analytic = try #require(RayTracedRoomRenderer(
            device  : device,
            denoises: false
        ))
        try Self.render(
            Self.room(.tilted),
            with  : analytic,
            device: device
        )
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(4))
        }
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
        let width : Int
        let height: Int
        let size  : CGSize
        let bytes : [UInt8]

        func luma(_ x: Int, _ y: Int) -> Double {
            let column = min(width - 1, Int((Double(x) + 0.5) * Double(width) / size.width))
            let row = min(height - 1, Int((Double(y) + 0.5) * Double(height) / size.height))
            let index = (row * width + column) * 4
            return 0.2126 * Double(bytes[index + 2]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index])
        }
    }

    /// Renders `uniforms` into its ready bucket, or at one pixel per point, and reads it back.
    @discardableResult
    private static func render(
        _ uniforms   : RoomLightUniforms,
        with renderer: any RoomRenderer,
        device       : MTLDevice,
        size         : CGSize = CGSize(width: 127, height: 104)
    ) throws -> Pixels {
        let outputSize = (renderer as? RayTracedRoomRenderer)?.denoisedPixelSize ?? size
        let width      = Int(outputSize.width)
        let height     = Int(outputSize.height)
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
            width : width,
            height: height,
            size  : size,
            bytes : bytes
        )
    }
}
