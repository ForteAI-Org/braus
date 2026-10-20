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
        #expect(LightingPath.choose(supportsRaytracing: false, override: nil) == .precomputed)
        #expect(LightingPath.choose(supportsRaytracing: true, override: nil) == .rayTraced)
        #expect(LightingPath.choose(supportsRaytracing: true, override: "precomputed") == .precomputed)
        #expect(LightingPath.choose(supportsRaytracing: false, override: "raytraced") == .precomputed)
    }

    @Test("Uniforms follow the status")
    func uniforms() {
        let busy = RoomLightUniforms(
            status     : .busy,
            tint       : .gray,
            hasOccupant: true
        )
        #expect(busy.strength == 1)
        #expect(busy.lightColor == SIMD3<Float>(1, 176.0 / 255, 72.0 / 255))

        let off = RoomLightUniforms(
            status     : .off,
            tint       : .gray,
            hasOccupant: true
        )
        #expect(off.strength == 0)
        // Three float4 in RoomLight.metal.
        #expect(MemoryLayout<RoomLightUniforms.Packed>.stride == 48)
    }

    @Test("The view renders on demand")
    func onDemand() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = RoomLightView(
            device  : device,
            uniforms: RoomLightUniforms(
                status     : .busy,
                tint       : .gray,
                hasOccupant: true
            )
        )
        #expect(view.isPaused == true)
        #expect(view.enableSetNeedsDisplay == true)
    }

    @Test("A busy room flickers and a waiting room breathes, neither under Reduce Motion")
    func ambientMotion() throws {
        defer { RestylingMotion.overrideReducesMotion = nil }
        RestylingMotion.overrideReducesMotion = false
        let device = try #require(MTLCreateSystemDefaultDevice())
        func room(_ status: WorkerStatus) -> RoomLightUniforms {
            RoomLightUniforms(
                status     : status,
                tint       : .gray,
                hasOccupant: true
            )
        }
        let view = RoomLightView(
            device  : device,
            uniforms: room(.busy)
        )
        func ambient() -> CAAnimation? {
            view.layer?.animation(forKey: RoomLightView.ambientKey)
        }
        let flicker = try #require(ambient() as? CAKeyframeAnimation)
        #expect(flicker.keyPath == "opacity" && flicker.duration == 3.4)

        view.uniforms = room(.waiting)
        let breath = try #require(ambient() as? CABasicAnimation)
        #expect(breath.keyPath == "opacity" && breath.duration * 2 == 2.2 && breath.autoreverses)

        view.uniforms = room(.free)
        #expect(ambient() == nil)

        RestylingMotion.overrideReducesMotion = true
        view.uniforms = room(.busy)
        #expect(ambient() == nil)
    }

    @Test("The precomputed path renders without hardware ray tracing")
    func precomputed() throws {
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(PrecomputedRoomRenderer(device: device))
        try expectLitRoom(renderer, device: device)
    }

    @Test("The ray-traced path lights the room")
    func rayTraced() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try #require(device.supportsRaytracing)
        let renderer = try #require(RayTracedRoomRenderer(device: device))
        try expectLitRoom(renderer, device: device)
    }

    /// Renders a busy room of 128 × 104 pixels at one pixel per point and checks that the light pools
    /// warm at the centre. The room is empty, so the centre pixel shows the floor, not the sphere.
    private func expectLitRoom(
        _ renderer: any RoomRenderer,
        device    : MTLDevice
    ) throws {
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
        let queue         = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        renderer.encode(
            RoomLightUniforms(
                status     : .busy,
                tint       : .gray,
                hasOccupant: false
            ),
            size         : CGSize(width: width, height: height),
            into         : texture,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: width * 4,
            from       : MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        // BGRA order.
        func pixel(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int) {
            let index = (y * width + x) * 4
            return (Int(pixels[index + 2]), Int(pixels[index + 1]), Int(pixels[index]))
        }
        let centre = pixel(width / 2, height / 2)
        let corner = pixel(1, 1)
        #expect(centre.red + centre.green + centre.blue > corner.red + corner.green + corner.blue)
        #expect(centre.red > centre.blue)
    }
}
