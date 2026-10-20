//
//  RoomLightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit
import MetalKit
import QuartzCore
import Testing
@testable import Braus

@Suite("RoomLight", .serialized)
@MainActor
struct RoomLightTests {

    @Test("Without hardware ray tracing the light is precomputed")
    func pathChoice() {
        func choose(_ isAppleFamily9: Bool, _ supportsRaytracing: Bool, _ override: String?) -> LightingPath {
            LightingPath.choose(
                isAppleFamily9    : isAppleFamily9,
                supportsRaytracing: supportsRaytracing,
                override          : override
            )
        }
        // M3 and later.
        #expect(choose(true, true, nil) == .rayTraced)
        #expect(choose(true, true, "precomputed") == .precomputed)
        #expect(choose(true, true, "raytraced") == .rayTraced)
        // M1 and M2, Intel and AMD GPUs: Metal reports ray tracing, traced in software.
        #expect(choose(false, true, nil) == .precomputed)
        #expect(choose(false, true, "raytraced") == .precomputed)
        #expect(choose(false, false, "raytraced") == .precomputed)
    }

    @Test("This GPU's path follows its family")
    func devicePath() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let path   = LightingPath.choose(
            for     : device,
            override: nil
        )
        #expect(path == (device.supportsFamily(.apple9) && device.supportsRaytracing ? .rayTraced : .precomputed))
    }

    @Test("Uniforms follow the status")
    func uniforms() {
        let busy = room(.busy)
        #expect(busy.strength == 1)
        #expect(busy.lightColor == SIMD3<Float>(1, 176.0 / 255, 72.0 / 255))
        #expect(room(.off).strength == 0)
        // Four float4 in RoomLight.metal.
        #expect(MemoryLayout<RoomLightUniforms.Packed>.stride == 64)
    }

    @Test("The view renders on demand")
    func onDemand() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view   = RoomLightView(
            device  : device,
            uniforms: room(.busy)
        )
        #expect(view.isPaused == true)
        #expect(view.enableSetNeedsDisplay == true)
        #expect(view.path != nil)
    }

    @Test("A different uniforms value requests a render, the same one does not")
    func uniformsRequestRender() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view   = RoomLightView(
            device  : device,
            uniforms: room(.busy)
        )
        let before = view.requestedRenders
        view.uniforms = room(.busy)
        #expect(view.requestedRenders == before)
        view.uniforms = room(.waiting)
        #expect(view.requestedRenders == before + 1)
    }

    @Test("A busy light flickers and a waiting light breathes, neither under Reduce Motion")
    func pulse() throws {
        let busy = RoomLightView.pulseWeights(
            for          : .busy,
            reducesMotion: false
        )
        #expect(busy.count == RoomLightView.framesPerCycle)
        #expect(busy.first == 1)
        #expect(abs((busy.min() ?? 0) - 0.8) < 0.05)

        let waiting = RoomLightView.pulseWeights(
            for          : .waiting,
            reducesMotion: false
        )
        #expect(waiting.count == RoomLightView.framesPerCycle)
        #expect(abs((waiting.min() ?? 0) - 0.55) < 0.01)

        #expect(RoomLightView.pulseWeights(for: .free, reducesMotion: false).isEmpty)
        #expect(RoomLightView.pulseWeights(for: .off, reducesMotion: false).isEmpty)
        #expect(RoomLightView.pulseWeights(for: .busy, reducesMotion: true).isEmpty)
        #expect(RoomLightView.pulseWeights(for: .waiting, reducesMotion: true).isEmpty)

        let frame = try #require(
            CGContext(
                data            : nil,
                width           : 1,
                height          : 1,
                bitsPerComponent: 8,
                bytesPerRow     : 4,
                space           : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.noneSkipFirst.rawValue
            )?.makeImage()
        )
        let frames  = Array(repeating: frame, count: RoomLightView.framesPerCycle)
        let flicker = try #require(RoomLightView.pulse(frames, for: .busy))
        #expect(flicker.keyPath == "contents" && flicker.duration == 3.4)
        #expect(flicker.values?.count == frames.count + 1)
        // Phased to the host clock, as the brows' tint is.
        #expect(flicker.beginTime == RoomLightView.pulseBeginTime(in: nil))
        let breath = try #require(RoomLightView.pulse(frames, for: .waiting))
        #expect(breath.duration == 2.2)
        #expect(RoomLightView.pulse(frames, for: .free) == nil)
    }

    @Test("Pulse frames are shared only on Apple GPUs, managed on Intel and AMD")
    func frameStorage() {
        // Apple silicon.
        #expect(RoomLightView.frameStorageMode(isAppleGPU: true, hasUnifiedMemory: true) == .shared)
        // An integrated Intel GPU reports unified memory, yet takes no shared textures.
        #expect(RoomLightView.frameStorageMode(isAppleGPU: false, hasUnifiedMemory: true) == .managed)
        // A discrete AMD or Intel GPU.
        #expect(RoomLightView.frameStorageMode(isAppleGPU: false, hasUnifiedMemory: false) == .managed)
    }

    @Test("The precomputed path renders without hardware ray tracing")
    func precomputed() throws {
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(PrecomputedRoomRenderer(device: device))
        try expectLitRoom(renderer, device: device)
        try expectContactShadow(renderer, device: device)
    }

    @Test("The ray-traced path lights the room")
    func rayTraced() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try #require(device.supportsRaytracing)
        let renderer = try #require(RayTracedRoomRenderer(device: device))
        try expectLitRoom(renderer, device: device)
        try expectContactShadow(renderer, device: device)
    }

    private func room(
        _ status   : WorkerStatus,
        hasOccupant: Bool = true
    ) -> RoomLightUniforms {
        RoomLightUniforms(
            status     : status,
            tint       : .gray,
            hasOccupant: hasOccupant
        )
    }

    /// A busy room's light pools warm at the centre. The room is empty, so the centre pixel shows
    /// the floor, not the sphere.
    private func expectLitRoom(
        _ renderer: any RoomRenderer,
        device    : MTLDevice
    ) throws {
        let image  = try render(
            room(.busy, hasOccupant: false),
            with  : renderer,
            device: device
        )
        let centre = image.pixel(image.width / 2, image.height / 2)
        let corner = image.pixel(8, 8)
        #expect(centre.red + centre.green + centre.blue > corner.red + corner.green + corner.blue)
        #expect(centre.red > centre.blue)
    }

    /// With the worker in the room, the floor just below the sphere is darker than the same floor
    /// with the room empty: the sphere casts its shadow there.
    private func expectContactShadow(
        _ renderer: any RoomRenderer,
        device    : MTLDevice
    ) throws {
        let occupied = try render(
            room(.busy),
            with  : renderer,
            device: device
        )
        let empty = try render(
            room(.busy, hasOccupant: false),
            with  : renderer,
            device: device
        )
        let radius = Int(0.17 * Double(occupied.height))
        let x      = occupied.width / 2
        let y      = occupied.height / 2 + radius + 3
        #expect(occupied.pixel(x, y).red + 6 < empty.pixel(x, y).red)
    }

    /// Pixels is a rendered room read back, in BGRA order.
    private struct Pixels {
        let width : Int
        let height: Int
        let bytes : [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index + 2]), Int(bytes[index + 1]), Int(bytes[index]))
        }
    }

    /// Renders `uniforms` at one pixel per point into a room of 128 × 104 and reads it back.
    private func render(
        _ uniforms: RoomLightUniforms,
        with renderer: any RoomRenderer,
        device    : MTLDevice
    ) throws -> Pixels {
        let width  = 128
        let height = 104
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
            size         : CGSize(width: width, height: height),
            into         : texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from       : MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        return Pixels(
            width : width,
            height: height,
            bytes : bytes
        )
    }
}
