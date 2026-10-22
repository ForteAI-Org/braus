//
//  RoomLightingTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import Metal
import QuartzCore
import Testing
@testable import Braus

@Suite("RoomLighting", .serialized)
@MainActor
struct RoomLightingTests {

    @Test("A worker's screen lights its tilted room while it uses one, whatever its status")
    func screenFollowsUsesScreen() throws {
        func screen(
            _ status   : WorkerStatus,
            screenLit  : Bool = true,
            camera     : RoomCamera = .tilted,
            hasOccupant: Bool = true
        ) -> Float {
            RoomLightUniforms(
                status     : status,
                shape      : .circle,
                hasOccupant: hasOccupant,
                camera     : camera,
                screenLit  : screenLit
            ).screenStrength
        }
        for status in WorkerStatus.allCases {
            #expect(screen(status) == 1, "\(status)")
            #expect(screen(status, screenLit: false) == 0, "\(status)")
        }
        #expect(screen(.busy, camera: .top) == 0)
        #expect(screen(.busy, hasOccupant: false) == 0)

        // The screen's image changes a busy room's pixels while its worker uses one, and nothing otherwise.
        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(PrecomputedRoomRenderer(device: device))
        for screenLit in [true, false] {
            let images = try Self.render(
                Self.room(.busy, screenLit: screenLit),
                weights : [SIMD2(1, 1), SIMD2(1, 0)],
                renderer: renderer,
                device  : device
            )
            #expect((images[0] != images[1]) == screenLit, "\(screenLit)")
        }
    }

    @Test("The hero's capsule lights the worker's front in its tone, in the screen's place")
    func capsuleLightsTheFront() throws {
        func hero(
            _ capsule: SIMD4<Float>,
            status   : WorkerStatus = .free,
            camera   : RoomCamera = .tilted
        ) -> RoomLightUniforms {
            RoomLightUniforms(
                status      : status,
                shape       : .circle,
                hasOccupant : true,
                camera      : camera,
                lean        : HouseWorkerPortrait.lean,
                capsuleLight: capsule
            )
        }
        let busy = hero(
            HeroLight.capsuleLight(for: .busy),
            status: .busy
        )
        #expect(busy.screenStrength == 0 && busy.capsuleStrength > 0 && busy.hasFrontLight)
        #expect(!hero(HeroLight.capsuleLight(for: .busy), camera: .top).hasFrontLight)
        #expect(!hero(.zero).hasFrontLight)
        #expect(busy.packed(size: CGSize(width: 127, height: 104), pixelWidth: 127).capsule.w == busy.capsuleStrength)

        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(PrecomputedRoomRenderer(device: device))
        // The worker's front face under its brows, where the capsule's light rises onto it.
        let size  = CGSize(width: 127, height: 104)
        let face  = try #require(RoomCamera.tilted.face(of: .circle, in: size, lean: HouseWorkerPortrait.lean))
        let lower = Double(RoomLightUniforms.Shape(size: size, lean: HouseWorkerPortrait.lean).sphereRadius) * 0.7
        let x     = Int(size.width / 2 + face.anchor.dx)
        let y     = Int(size.height / 2 + face.anchor.dy + lower)
        func front(_ uniforms: RoomLightUniforms) throws -> (red: Double, green: Double, blue: Double) {
            Self.mean(
                try Self.render(uniforms, renderer: renderer, device: device)[0],
                x: x - 4..<x + 4,
                y: y - 3..<y + 3
            )
        }
        let unlit = try front(hero(.zero))
        let warm  = try front(hero(HeroLight.capsuleLight(for: .busy)))
        let cool  = try front(hero(HeroLight.capsuleLight(for: .waiting)))
        let moon  = try front(hero(HeroLight.capsuleLight(for: .off)))
        func level(_ colour: (red: Double, green: Double, blue: Double)) -> Double {
            colour.red + colour.green + colour.blue
        }
        #expect(level(warm) > level(unlit) + 12, "\(warm) against \(unlit)")
        #expect(level(moon) > level(unlit) && level(moon) < level(warm), "\(moon)")
        #expect(warm.red - warm.blue > cool.red - cool.blue + 4, "\(warm) against \(cool)")

        // The capsule's light is the third image, the one a screen would write.
        let images = try Self.render(
            busy,
            weights : [SIMD2(1, 1), SIMD2(1, 0)],
            renderer: renderer,
            device  : device
        )
        #expect(images[0] != images[1])
    }

    @Test("A room that is off is lit by a cool moon and by no warm lamp")
    func moonlight() throws {
        let off = Self.room(.off)
        #expect(off.moonStrength == 1 && off.strength == 0)
        #expect(Self.room(.busy).moonStrength == 0)
        #expect(RoomLightUniforms(status: .off, shape: .circle, hasOccupant: true, camera: .top).moonStrength == 0)

        let device   = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(PrecomputedRoomRenderer(device: device))
        let size     = CGSize(width: 127, height: 104)
        // The floor in front of the worker, toward the camera.
        let tilted = try Self.render(off, renderer: renderer, device: device)[0]
        let unlit  = try Self.render(
            RoomLightUniforms(status: .off, shape: .circle, hasOccupant: true, camera: .top),
            renderer: renderer,
            device  : device
        )[0]
        let floor  = Self.mean(tilted, x: 20..<Int(size.width) - 20, y: Int(size.height) - 16..<Int(size.height) - 4)
        let before = Self.mean(unlit, x: 20..<Int(size.width) - 20, y: Int(size.height) - 16..<Int(size.height) - 4)
        #expect(floor.blue > floor.red + 3, "\(floor)")
        #expect(floor.blue > before.blue + 6, "\(floor) against \(before)")
    }

    @Test("Out of rooms the body has no crescent of its status's colour, only a faint neutral bounce")
    func noColouredCrescent() {
        for status in WorkerStatus.allCases {
            let layer = MascotLayer()
            layer.frame  = CGRect(x: 0, y: 0, width: 56, height: 56)
            layer.status = status
            layer.layoutIfNeeded()
            var gradients: [CAGradientLayer] = []
            func collect(_ layer: CALayer) {
                if let gradient = layer as? CAGradientLayer { gradients.append(gradient) }
                for sublayer in layer.sublayers ?? [] { collect(sublayer) }
            }
            collect(layer)
            let light = status.light
            for gradient in gradients {
                for color in (gradient.colors as? [CGColor]) ?? [] {
                    guard
                        let light,
                        let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
                    else { continue }
                    let matches = abs(rgb[0] - light.red) < 0.02 && abs(rgb[1] - light.green) < 0.02 && abs(rgb[2] - light.blue) < 0.02
                    #expect(!(matches && color.alpha > 0.06), "\(status): \(color)")
                }
            }
        }
    }

    @Test("Each brow's enamel, its shading and its contact shadow morph together, the shadow beneath")
    func enamelFollowsTheMorph() throws {
        let layer = MascotLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        layer.layoutIfNeeded()
        layer.show(.working, animated: true)
        for brow in [layer.leftBrow, layer.rightBrow] {
            let contact = layer.contact(of: brow)
            let layers  = layer.outlineLayers(of: brow)
            #expect(layers.contains { $0 === contact })
            #expect(layers.count == 6)
            for outline in layers {
                #expect(outline.path == brow.path)
                #expect(outline.animation(forKey: "path") != nil || HouseMotion.reducesMotion)
            }
            let siblings = try #require(layer.sublayers)
            let below    = try #require(siblings.firstIndex { $0 === contact })
            let above    = try #require(siblings.firstIndex { $0 === brow })
            #expect(below < above)
            #expect(contact.position.y < brow.position.y)
        }
    }

    @Test("The grid's worker is a sixth larger and stays inside its tilted room, for every shape and size")
    func largerWorkerInside() {
        let grid = RoomLightUniforms.Shape(size: CGSize(width: 127, height: 104))
        let ratio = grid.sphereRadius / (0.17 * 104)
        #expect(ratio > 1.15 && ratio < 1.2)
        for size in [CGSize(width: 127, height: 104), CGSize(width: 260, height: 104), CGSize(width: 120, height: 92)] {
            let perspective = RoomCamera.Perspective(size: size)
            let radius      = Double(RoomLightUniforms.Shape(size: size).sphereRadius)
            for shape in WorkerShape.allCases {
                let outline = shape.outline
                let reach   = RoomCamera.slab(of: outline) + outline.corner + outline.dome
                for point in outline.points(growth: outline.corner, pointsPerTurn: 48) {
                    for side in [-1.0, 1.0] {
                        let shown = perspective.project(SIMD3(
                            Double(size.width) / 2 + radius * point.x,
                            perspective.bodyDepth + side * radius * reach,
                            radius * (outline.bottom - point.y)
                        ))
                        #expect(shown.x > 0 && shown.x < size.width && shown.y > 0 && shown.y < size.height, "\(shape) in \(size): \(shown)")
                    }
                }
            }
        }
    }

    private static func room(
        _ status : WorkerStatus,
        screenLit: Bool = false
    ) -> RoomLightUniforms {
        RoomLightUniforms(
            status     : status,
            shape      : .circle,
            hasOccupant: true,
            camera     : .tilted,
            screenLit  : screenLit
        )
    }

    /// The room rendered at one pixel per point into one target per pair of weights, the lamp's and
    /// the screen's, read back in BGRA order.
    private static func render(
        _ uniforms: RoomLightUniforms,
        weights   : [SIMD2<Float>] = [SIMD2(1, 1)],
        renderer  : any RoomRenderer,
        device    : MTLDevice
    ) throws -> [[UInt8]] {
        let size    = CGSize(width: 127, height: 104)
        let targets = try weights.map { weight -> (texture: MTLTexture, weight: SIMD2<Float>) in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width      : Int(size.width),
                height     : Int(size.height),
                mipmapped  : false
            )
            descriptor.usage       = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .shared
            return (try #require(device.makeTexture(descriptor: descriptor)), weight)
        }
        let commandBuffer = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(
            uniforms,
            size         : size,
            into         : targets,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return targets.map { target in
            var bytes = [UInt8](
                repeating: 0,
                count    : Int(size.width) * Int(size.height) * 4
            )
            target.texture.getBytes(
                &bytes,
                bytesPerRow: Int(size.width) * 4,
                from       : MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)),
                mipmapLevel: 0
            )
            return bytes
        }
    }

    /// The mean colour of a block of a 127-pixel-wide BGRA image, in 8-bit levels.
    private static func mean(
        _ bytes: [UInt8],
        x      : Range<Int>,
        y      : Range<Int>
    ) -> (red: Double, green: Double, blue: Double) {
        var total = (red: 0.0, green: 0.0, blue: 0.0)
        for row in y {
            for column in x {
                let index = (row * 127 + column) * 4
                total.red   += Double(bytes[index + 2])
                total.green += Double(bytes[index + 1])
                total.blue  += Double(bytes[index])
            }
        }
        let count = Double(x.count * y.count)
        return (total.red / count, total.green / count, total.blue / count)
    }
}
