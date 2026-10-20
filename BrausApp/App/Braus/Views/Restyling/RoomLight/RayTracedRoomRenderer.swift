//
//  RayTracedRoomRenderer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Metal

/// RayTracedRoomRenderer lights a room with hardware ray tracing.
///
/// The floor, the four walls and a tessellated sphere form one primitive acceleration structure,
/// rebuilt only when the room's size or occupancy changes. Per change, one compute pass casts a
/// jittered primary ray per pixel, shadow rays to the disc lamp, one diffuse bounce and, on the
/// sphere, one reflection ray; it accumulates 16 such frames in the kernel and writes the average,
/// then stops.
final class RayTracedRoomRenderer: RoomRenderer {
    let commandQueue: MTLCommandQueue

    private let device  : MTLDevice
    private let pipeline: MTLComputePipelineState
    private var scene   : Scene?

    /// Fails when the device has no hardware ray tracing, gives no queue or the kernel cannot be loaded.
    init?(device: MTLDevice) {
        guard
            device.supportsRaytracing,
            let queue    = device.makeCommandQueue(),
            let pipeline = Self.pipeline(
                named : "traceRoom",
                device: device
            )
        else { return nil }
        self.device   = device
        commandQueue  = queue
        self.pipeline = pipeline
    }

    func encode(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        into texture : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard
            let structure = structure(
                size         : size,
                isOccupied   : uniforms.hasOccupant,
                commandBuffer: commandBuffer
            ),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        encoder.setAccelerationStructure(
            structure,
            bufferIndex: 1
        )
        dispatch(
            pipeline,
            uniforms: uniforms,
            size    : size,
            into    : texture,
            encoder : encoder
        )
    }

    /// Scene is a built acceleration structure and the room it was built for. It keeps the build's
    /// descriptor, which holds the vertex buffers, and its scratch buffer until the next rebuild, so
    /// the GPU never reads a released buffer.
    private struct Scene {
        let size      : CGSize
        let isOccupied: Bool
        let structure : MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let scratch   : MTLBuffer
    }

    private static let sphereSlices = 64
    private static let sphereStacks = 32

    /// The acceleration structure for the room, encoding its build into `commandBuffer` when the room
    /// changed, before the pass that traces it.
    private func structure(
        size         : CGSize,
        isOccupied   : Bool,
        commandBuffer: MTLCommandBuffer
    ) -> MTLAccelerationStructure? {
        if let scene, scene.size == size, scene.isOccupied == isOccupied {
            return scene.structure
        }
        var geometries = [
            Self.floor(size),
            Self.walls(size),
        ]
        if isOccupied {
            geometries.append(Self.sphere(size))
        }
        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = geometries.compactMap(triangleGeometry)
        guard descriptor.geometryDescriptors?.count == geometries.count else { return nil }

        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard
            let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
            let scratch   = device.makeBuffer(
                length : sizes.buildScratchBufferSize,
                options: .storageModePrivate
            ),
            let encoder = commandBuffer.makeAccelerationStructureCommandEncoder()
        else { return nil }
        encoder.build(
            accelerationStructure: structure,
            descriptor           : descriptor,
            scratchBuffer        : scratch,
            scratchBufferOffset  : 0
        )
        encoder.endEncoding()
        scene = Scene(
            size      : size,
            isOccupied: isOccupied,
            structure : structure,
            descriptor: descriptor,
            scratch   : scratch
        )
        return structure
    }

    private func triangleGeometry(_ vertices: [SIMD3<Float>]) -> MTLAccelerationStructureTriangleGeometryDescriptor? {
        let stride = MemoryLayout<SIMD3<Float>>.stride
        guard let buffer = device.makeBuffer(
            bytes  : vertices,
            length : vertices.count * stride,
            options: .storageModeShared
        ) else { return nil }
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer  = buffer
        geometry.vertexStride  = stride
        geometry.vertexFormat  = .float3
        geometry.triangleCount = vertices.count / 3
        geometry.opaque        = true
        return geometry
    }

    /// The scene's proportions; RoomLight.metal uses the same.
    private static func proportions(_ size: CGSize) -> (width: Float, height: Float, reach: Float, wall: Float, radius: Float) {
        let side = Float(min(size.width, size.height))
        return (
            width : Float(size.width),
            height: Float(size.height),
            reach : 0.09 * side,
            wall  : 0.18 * side,
            radius: 0.17 * side
        )
    }

    /// Two triangles for the quad a, b, c, d.
    private static func quad(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        _ d: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        [a, b, c, a, c, d]
    }

    private static func floor(_ size: CGSize) -> [SIMD3<Float>] {
        let room = proportions(size)
        return quad(
            SIMD3(room.reach, room.reach, 0),
            SIMD3(room.width - room.reach, room.reach, 0),
            SIMD3(room.width - room.reach, room.height - room.reach, 0),
            SIMD3(room.reach, room.height - room.reach, 0)
        )
    }

    /// The four walls, left, top, right, bottom, two triangles each: the shader finds a wall's
    /// normal from its primitive index divided by two.
    private static func walls(_ size: CGSize) -> [SIMD3<Float>] {
        let room = proportions(size)
        let (w, h, r, z) = (room.width, room.height, room.reach, room.wall)
        let outer = [SIMD3<Float>(0, 0, z), SIMD3(w, 0, z), SIMD3(w, h, z), SIMD3(0, h, z)]
        let inner = [SIMD3<Float>(r, r, 0), SIMD3(w - r, r, 0), SIMD3(w - r, h - r, 0), SIMD3(r, h - r, 0)]
        // Corners in order top left, top right, bottom right, bottom left; each wall joins two.
        let corners = [(3, 0), (0, 1), (1, 2), (2, 3)]
        return corners.flatMap { first, second in
            quad(
                outer[first],
                outer[second],
                inner[second],
                inner[first]
            )
        }
    }

    private static func sphere(_ size: CGSize) -> [SIMD3<Float>] {
        let room   = proportions(size)
        let centre = SIMD3(room.width / 2, room.height / 2, room.radius)
        func point(_ slice: Int, _ stack: Int) -> SIMD3<Float> {
            let polar   = Float.pi * Float(stack) / Float(sphereStacks)
            let azimuth = 2 * Float.pi * Float(slice) / Float(sphereSlices)
            return centre + room.radius * SIMD3(
                sin(polar) * cos(azimuth),
                sin(polar) * sin(azimuth),
                cos(polar)
            )
        }
        var vertices: [SIMD3<Float>] = []
        for stack in 0..<sphereStacks {
            for slice in 0..<sphereSlices {
                vertices += quad(
                    point(slice, stack),
                    point(slice + 1, stack),
                    point(slice + 1, stack + 1),
                    point(slice, stack + 1)
                )
            }
        }
        return vertices
    }
}
