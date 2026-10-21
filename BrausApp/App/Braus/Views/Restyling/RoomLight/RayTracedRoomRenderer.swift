//
//  RayTracedRoomRenderer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import Metal

/// RayTracedRoomRenderer lights a room with hardware ray tracing.
///
/// The room (a floor with a rounded outline and its cove walls) and the worker's tessellated body
/// form one primitive acceleration structure, rebuilt only when the room's size, occupancy or shape
/// changes. The body is a triangle mesh of its outline's bevel, built from the same `ShapeOutline`
/// the shader shades, so the hardware intersects it like the room and its shadow follows the outline.
/// Per change, one compute pass accumulates 64 frames per pixel in linear light: a jittered primary
/// ray, shadow rays to the disc lamp, one diffuse bounce that also gives the ambient occlusion, and on
/// the body GGX reflection rays off its metal. Then it stops.
final class RayTracedRoomRenderer: RoomRenderer {
    let commandQueue   : MTLCommandQueue
    let resolvePipeline: MTLComputePipelineState

    private let device  : MTLDevice
    private let pipeline: MTLComputePipelineState
    private var scene   : Scene?

    /// Fails when the device has no ray tracing, gives no queue or a kernel cannot be loaded.
    init?(device: MTLDevice) {
        guard
            device.supportsRaytracing,
            let queue    = device.makeCommandQueue(),
            let pipeline = Self.pipeline(
                named : "traceRoom",
                device: device
            ),
            let resolve = Self.pipeline(
                named : "resolveRoom",
                device: device
            )
        else { return nil }
        self.device     = device
        commandQueue    = queue
        self.pipeline   = pipeline
        resolvePipeline = resolve
    }

    func encodeImages(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        base         : MTLTexture,
        light        : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard
            let structure = structure(
                size         : size,
                occupant     : uniforms.hasOccupant ? uniforms.shape : nil,
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
            base    : base,
            light   : light,
            encoder : encoder
        )
    }

    /// Scene is a built acceleration structure and the room it was built for. It keeps the build's
    /// descriptor, which holds the vertex buffers, and its scratch buffer until the next rebuild, so
    /// the GPU never reads a released buffer.
    private struct Scene {
        let size      : CGSize
        let occupant  : WorkerShape?
        let structure : MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let scratch   : MTLBuffer
    }

    private static let coveRings      = 10
    private static let cornerSegments = 12

    /// The body's rings from its equator to the top of its bevel, and its outline's points per turn.
    private static let bevelRings    = 16
    private static let pointsPerTurn = 96

    /// The acceleration structure for the room and the shape of the worker in it, encoding its build
    /// into `commandBuffer` when either changed, before the pass that traces it.
    private func structure(
        size         : CGSize,
        occupant     : WorkerShape?,
        commandBuffer: MTLCommandBuffer
    ) -> MTLAccelerationStructure? {
        if let scene, scene.size == size, scene.occupant == occupant {
            return scene.structure
        }
        // Geometry 0 is the room and 1 the body, as RoomLight.metal expects.
        var geometries = [Self.room(size)]
        if let occupant {
            geometries.append(Self.body(
                size,
                outline: occupant.outline
            ))
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
            occupant  : occupant,
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

    /// Two triangles for the quad a, b, c, d.
    private static func quad(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        _ d: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        [a, b, c, a, c, d]
    }

    /// The floor and the cove walls. Each ring follows the room's rounded outline inset by a share
    /// of the wall's reach, at the cove's height there, z = height × t²; the innermost ring is the
    /// floor's edge, closed by a fan from the centre. The shader shades every hit from the same
    /// outline, so the facets never show.
    private static func room(_ size: CGSize) -> [SIMD3<Float>] {
        let shape   = RoomLightUniforms.Shape(size: size)
        let width   = Float(size.width)
        let height  = Float(size.height)
        let rings: [[SIMD3<Float>]] = (0...coveRings).map { index in
            let inset = shape.wallReach * Float(index) / Float(coveRings)
            let rise  = 1 - Float(index) / Float(coveRings)
            return outline(
                width : width,
                height: height,
                inset : inset,
                radius: shape.cornerRadius - inset,
                z     : shape.wallHeight * rise * rise
            )
        }
        var vertices: [SIMD3<Float>] = []
        for (outer, inner) in zip(rings, rings.dropFirst()) {
            for index in outer.indices {
                let next = (index + 1) % outer.count
                vertices += quad(
                    outer[index],
                    outer[next],
                    inner[next],
                    inner[index]
                )
            }
        }
        let floor  = rings[coveRings]
        let centre = SIMD3<Float>(width / 2, height / 2, 0)
        for index in floor.indices {
            vertices += [centre, floor[index], floor[(index + 1) % floor.count]]
        }
        return vertices
    }

    /// The points of a rounded rectangle inset by `inset` from the room's edges, at height `z`,
    /// clockwise on screen from the top-left corner.
    private static func outline(
        width : Float,
        height: Float,
        inset : Float,
        radius: Float,
        z     : Float
    ) -> [SIMD3<Float>] {
        let corners: [(x: Float, y: Float, start: Float)] = [
            (inset + radius, inset + radius, Float.pi),
            (width - inset - radius, inset + radius, Float.pi * 1.5),
            (width - inset - radius, height - inset - radius, 0),
            (inset + radius, height - inset - radius, Float.pi * 0.5),
        ]
        return corners.flatMap { corner in
            (0...cornerSegments).map { step in
                let angle = corner.start + Float.pi / 2 * Float(step) / Float(cornerSegments)
                return SIMD3(
                    corner.x + radius * cos(angle),
                    corner.y + radius * sin(angle),
                    z
                )
            }
        }
    }

    /// The worker's body around the room's centre, in points: rings of its outline grown from the
    /// core along the bevel's quarter circle, from the equator to the core, mirrored below, and the
    /// core as a flat cap on top and bottom. The dome is left out, so the mesh lies inside the top the
    /// shader shades and no reflected ray starts inside it. For the circle it is a sphere.
    private static func body(
        _ size : CGSize,
        outline: ShapeOutline
    ) -> [SIMD3<Float>] {
        let radius = Double(RoomLightUniforms.Shape(size: size).sphereRadius)
        let centre = SIMD2(Double(size.width) / 2, Double(size.height) / 2)
        let corner = outline.corner * radius
        func ring(
            _ index: Int,
            lower  : Bool
        ) -> [SIMD3<Float>] {
            let angle  = Double.pi / 2 * Double(index) / Double(bevelRings)
            let height = corner * (lower ? 1 - sin(angle) : 1 + sin(angle))
            return outline.points(
                growth       : outline.corner * cos(angle),
                pointsPerTurn: pointsPerTurn
            ).map { point in
                let place = centre + radius * point
                return SIMD3(Float(place.x), Float(place.y), Float(height))
            }
        }
        var vertices: [SIMD3<Float>] = []
        for lower in [false, true] {
            let rings = (0...bevelRings).map { ring($0, lower: lower) }
            for (outer, inner) in zip(rings, rings.dropFirst()) {
                for index in outer.indices {
                    let next = (index + 1) % outer.count
                    vertices += quad(
                        outer[index],
                        outer[next],
                        inner[next],
                        inner[index]
                    )
                }
            }
            let core = rings[bevelRings]
            let cap  = SIMD3(Float(centre.x), Float(centre.y), Float(lower ? 0 : 2 * corner))
            for index in core.indices {
                vertices += [cap, core[index], core[(index + 1) % core.count]]
            }
        }
        return vertices
    }
}
