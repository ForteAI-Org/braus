//
//  RoomCameraTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import CryptoKit
import Metal
import Testing
@testable import Braus

@Suite("RoomCamera", .serialized)
@MainActor
struct RoomCameraTests {

    /// The GPU the top view's digests were recorded on, from 09b7b881's renderers.
    nonisolated private static let recordingGPU = "Apple M4"

    /// The digest of each top-view render, by `Sample.name`: SHA-256, first 16 hex digits. Recorded at
    /// 09b7b881 and again once the grid's worker grew a sixth; the empty rooms are 09b7b881's.
    private static let topDigests: [String: String] = [
        "pc-busy-circle-empty-260x84"  : "944465b71b8272ba",
        "pc-busy-circle-in-127x104"    : "3a8a25840e93ded7",
        "pc-busy-lens-in-260x104"      : "e2da8adcc78780d5",
        "pc-busy-pentagon-in-260x104"  : "196f122737b8ccb7",
        "pc-free-hexagon-in-260x84"    : "35276a3b1cb4eb88",
        "pc-free-square-in-260x104"    : "97439ef8be9f418e",
        "pc-off-diamond-in-127x104"    : "78fb04554d917b72",
        "pc-waiting-capsule-in-127x104": "36088ddae0a79543",
        "pc-waiting-triangle-in-260x84": "60528188a01c886d",
        "rt-busy-circle-empty-260x84"  : "07eea9869362c828",
        "rt-busy-circle-in-127x104"    : "47700f2d80fb4ed3",
        "rt-busy-lens-in-260x104"      : "d40482cef9ceb14f",
        "rt-busy-pentagon-in-260x104"  : "f3332d3d5e284cf3",
        "rt-free-hexagon-in-260x84"    : "1d48c8936a24f83b",
        "rt-free-square-in-260x104"    : "20b8b02648c22846",
        "rt-off-diamond-in-127x104"    : "997ec3416339c5c0",
        "rt-waiting-capsule-in-127x104": "053c85aabb9267b6",
        "rt-waiting-triangle-in-260x84": "a96c24133432e47c",
    ]

    /// The digest of each tilted render, by `Sample.name`. Recorded at a53d9e46 and again with the
    /// screen, the moon, the metal that holds the light and the larger worker; the empty rooms are
    /// a53d9e46's. With the body's pose, three moved by fast math's rounding: one or two pixels each,
    /// one channel by 1/255; with its stretch and lean, the lens again by one pixel.
    private static let tiltedDigests: [String: String] = [
        "pc-busy-circle-empty-260x84"  : "b1ab02eb6a4dbe7b",
        "pc-busy-circle-in-127x104"    : "a50b3d946125ce12",
        "pc-busy-lens-in-260x104"      : "34bfd81d27855ce1",
        "pc-busy-pentagon-in-260x104"  : "3a6a682fc6e47ff7",
        "pc-free-hexagon-in-260x84"    : "ae0c65355301af4e",
        "pc-free-square-in-260x104"    : "225ee0238146a469",
        "pc-off-diamond-in-127x104"    : "a10103b31af4ba53",
        "pc-waiting-capsule-in-127x104": "ee48023366eba767",
        "pc-waiting-triangle-in-260x84": "419f68c5b72fd8b7",
        "rt-busy-circle-empty-260x84"  : "3c27fb0c2dbe18f1",
        "rt-busy-circle-in-127x104"    : "d2fd4ef6d5de8452",
        "rt-busy-lens-in-260x104"      : "d9162f68142ed3fd",
        "rt-busy-pentagon-in-260x104"  : "c3bf5330a224a112",
        "rt-free-hexagon-in-260x84"    : "1ffc2aa60a083aa3",
        "rt-free-square-in-260x104"    : "cfff675587f8950b",
        "rt-off-diamond-in-127x104"    : "f4321d2dfc068c4e",
        "rt-waiting-capsule-in-127x104": "e009b5ac28340252",
        "rt-waiting-triangle-in-260x84": "f58212bf597d8eb7",
    ]

    @Test("BRAUS_ROOM_CAMERA names the top camera, and anything else or nothing keeps the tilted one")
    func cameraSwitch() {
        #expect(RoomCamera(environment: nil) == .tilted)
        #expect(RoomCamera(environment: "top") == .top)
        #expect(RoomCamera(environment: "tilted") == .tilted)
        #expect(RoomCamera(environment: "Top") == .tilted)
        #expect(RoomCamera(environment: "") == .tilted)

        let uniforms = RoomLightUniforms(
            status     : .busy,
            shape      : .circle,
            hasOccupant: true
        )
        #expect(uniforms.camera == .top)
        // From above the camera's lanes stay zero, as the top view's kernels always read them.
        let packed = uniforms.packed(
            size      : CGSize(width: 127, height: 104),
            pixelWidth: 254
        )
        #expect(packed.camera == .zero && packed.room.w == 0)
    }

    @Test("The tilted window spans the cell: the back wall's top is its top edge, the floor's front edge its bottom")
    func windowSpansTheCell() {
        for (size, lean) in Self.rooms {
            let perspective = RoomCamera.Perspective(
                size: size,
                lean: lean
            )
            let corners: [(SIMD3<Double>, CGPoint)] = [
                (SIMD3(0, 0, perspective.wallTop), CGPoint(x: 0, y: 0)),
                (SIMD3(size.width, 0, perspective.wallTop), CGPoint(x: size.width, y: 0)),
                (SIMD3(0, perspective.depth, 0), CGPoint(x: 0, y: size.height)),
                (SIMD3(size.width, perspective.depth, 0), CGPoint(x: size.width, y: size.height)),
            ]
            for (point, corner) in corners {
                let shown = perspective.project(point)
                #expect(hypot(shown.x - corner.x, shown.y - corner.y) < 1e-9, "\(size): \(point)")
            }
            // The back wall's foot lies behind the window, so it shows narrower than the cell.
            let foot = perspective.project(SIMD3(0, 0, 0))
            #expect(foot.x > 0 && foot.y > 0 && foot.y < size.height / 2, "\(size): \(foot)")
            // The eye stands across from the worker, which shows where the room puts it.
            let worker = perspective.project(SIMD3(perspective.bodyX, perspective.bodyDepth, 10))
            let placed = RoomLightUniforms.Shape.bodyX(
                in  : size,
                lean: lean
            )
            #expect(abs(worker.x - placed) < 1e-9, "\(size) leaning \(lean)")
        }
    }

    @Test("In a tilted room the brows sit on the body, for every shape and room size, and in a row leaning left")
    func browsOnTheBody() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for (size, lean) in Self.rooms {
            for shape in WorkerShape.allCases {
                let face   = try #require(RoomCamera.tilted.face(
                    of  : shape,
                    in  : size,
                    lean: lean
                ))
                let width  = 2 * Double(RoomLightUniforms.Shape(
                    size: size,
                    lean: lean
                ).sphereRadius) * shape.outline.inradius
                let span   = 0.54 * width
                let apart  = face.xScale * (span - 0.455 * span) / 2
                let centre = SIMD2(Float(size.width / 2 + face.anchor.dx), Float(size.height / 2 + face.anchor.dy))
                // The anchor, both brows' centres, and a corner of the room, which must miss the body.
                let points = [
                    centre,
                    centre - SIMD2(Float(apart), 0),
                    centre + SIMD2(Float(apart), 0),
                    SIMD2(2, 2),
                ]
                let hits = try Self.tiltedBodyHits(
                    RoomLightUniforms(
                        status     : .busy,
                        shape      : shape,
                        hasOccupant: true,
                        camera     : .tilted,
                        lean       : lean,
                        screenLit  : true
                    ),
                    at    : points,
                    size  : size,
                    device: device
                )
                #expect(hits == [true, true, true, false], "\(shape) in \(size): \(face)")
                #expect(face.yScale <= 1.02 * face.xScale && face.yScale > 0.4 * face.xScale, "\(shape): \(face)")
            }
        }
    }

    @Test(
        "The floor plan's rooms render as recorded, from above and tilted, on both paths",
        .enabled(if: MTLCreateSystemDefaultDevice()?.name == recordingGPU)
    )
    func centreIsUnchanged() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var renderers: [(name: String, renderer: any RoomRenderer)] = [
            ("pc", try #require(PrecomputedRoomRenderer(device: device))),
        ]
        if let tracer = RayTracedRoomRenderer(device: device) {
            renderers.append(("rt", tracer))
        }
        let digests: [(camera: RoomCamera, table: [String: String])] = [
            (.top, Self.topDigests),
            (.tilted, Self.tiltedDigests),
        ]
        for (path, renderer) in renderers {
            for (camera, table) in digests {
                for sample in Self.samples {
                    var uniforms = sample.uniforms
                    uniforms.camera = camera
                    let name   = "\(path)-\(sample.name)"
                    let digest = try Self.digest(
                        uniforms,
                        size     : sample.size,
                        renderer : renderer,
                        device   : device
                    )
                    #expect(table[name] == digest, "\(camera) \(name): \(digest)")
                }
            }
        }
    }

    /// The grid's room, the wide first room and the compact one, and a row leaning left.
    private static let rooms: [(size: CGSize, lean: Float)] = [
        (CGSize(width: 127, height: 104), 0),
        (CGSize(width: 260, height: 104), 0),
        (CGSize(width: 120, height: 92), 0),
        (CGSize(width: 260, height: RoomLightTests.shallowRoomHeight), 1),
    ]

    /// Whether the tilted camera's ray through each of `points` meets the body, from RoomLight.metal's
    /// `tiltedBodyHits`.
    static func tiltedBodyHits(
        _ uniforms: RoomLightUniforms,
        at points : [SIMD2<Float>],
        size      : CGSize,
        device    : MTLDevice
    ) throws -> [Bool] {
        let pipeline = try #require(PrecomputedRoomRenderer.pipeline(
            named : "tiltedBodyHits",
            device: device
        ))
        var packed = uniforms.packed(
            size      : size,
            pixelWidth: Int(size.width)
        )
        let input = try #require(device.makeBuffer(
            bytes  : points,
            length : points.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ))
        let output = try #require(device.makeBuffer(
            length : points.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ))
        let queue         = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder       = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(
            &packed,
            length: MemoryLayout<RoomLightUniforms.Packed>.stride,
            index : 0
        )
        encoder.setBuffer(
            input,
            offset: 0,
            index : 1
        )
        encoder.setBuffer(
            output,
            offset: 0,
            index : 2
        )
        encoder.dispatchThreads(
            MTLSize(
                width : points.count,
                height: 1,
                depth : 1
            ),
            threadsPerThreadgroup: MTLSize(
                width : points.count,
                height: 1,
                depth : 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        let hits = output.contents().bindMemory(
            to      : Float.self,
            capacity: points.count
        )
        return (0..<points.count).map { hits[$0] > 0.5 }
    }

    /// Sample is one room the regression renders: a status, a shape, occupied or not, at a size.
    private struct Sample {
        let name    : String
        let uniforms: RoomLightUniforms
        let size    : CGSize
    }

    /// Every status and shape once, an empty room, and the grid's, the wide room's and a row's sizes.
    private static let samples: [Sample] = {
        let rooms: [(WorkerStatus, WorkerShape, Bool)] = [
            (.busy, .circle, true),
            (.free, .square, true),
            (.waiting, .triangle, true),
            (.off, .diamond, true),
            (.busy, .pentagon, true),
            (.free, .hexagon, true),
            (.waiting, .capsule, true),
            (.busy, .lens, true),
            (.busy, .circle, false),
        ]
        let sizes = [
            CGSize(width: 127, height: 104),
            CGSize(width: 260, height: 104),
            CGSize(width: 260, height: 84),
        ]
        return rooms.enumerated().map { index, room in
            let size = sizes[index % sizes.count]
            return Sample(
                name    : "\(room.0)-\(room.1)-\(room.2 ? "in" : "empty")-\(Int(size.width))x\(Int(size.height))",
                // Recorded while a busy worker always had its screen.
                uniforms: RoomLightUniforms(
                    status     : room.0,
                    shape      : room.1,
                    hasOccupant: room.2,
                    screenLit  : room.0 == .busy
                ),
                size    : size
            )
        }
    }()

    /// Renders `uniforms` at two pixels per point, as on a Retina display, and digests the pixels.
    private static func digest(
        _ uniforms: RoomLightUniforms,
        size      : CGSize,
        renderer  : any RoomRenderer,
        device    : MTLDevice
    ) throws -> String {
        let width      = Int(size.width) * 2
        let height     = Int(size.height) * 2
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
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
