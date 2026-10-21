//
//  RayTracedRoomRenderer.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import CoreGraphics
import Metal
import MetalFX

/// RayTracedRoomRenderer lights a room with hardware ray tracing.
///
/// The room (a floor with a rounded outline and its cove walls) and the worker's tessellated body
/// form one primitive acceleration structure, rebuilt only when the room's size, occupancy, shape,
/// camera, composition or the standing body's pose changes. The body is a triangle mesh of its outline's bevel, built from the
/// same `ShapeOutline` the shader shades, so the hardware intersects it like the room and its shadow
/// follows the outline.
/// Per change, one compute pass accumulates 64 frames per pixel in linear light: a jittered primary
/// ray, shadow rays to the disc lamp, one diffuse bounce that also gives the ambient occlusion, and on
/// the body GGX reflection rays off its metal. Then it stops. A room seen through the tilted camera
/// has tall walls with rounded coves, open at the front, a worker standing upright, and its own
/// kernel, which casts the camera's rays; a room leaning left has its own pair (`RoomKernels`).
///
/// When it `denoises`, a tilted room, centred or leaning, is traced instead at a reduced size in
/// `RoomDenoiser.burst` frames of `RoomDenoiser.samples` samples per pixel, with shadow rays to the lamp
/// in place of the body's analytic shadow, and MetalFX's denoised upscaler turns them into the
/// full-size images (`RoomDenoiser`).
final class RayTracedRoomRenderer: RoomRenderer {
    let commandQueue   : MTLCommandQueue
    let resolvePipeline: MTLComputePipelineState

    /// Whether tilted rooms are traced in denoised bursts.
    let denoises: Bool

    /// The denoised frames encoded so far, `RoomDenoiser.burst` per denoised render.
    private(set) var denoisedFrames = 0

    private let device         : MTLDevice
    private let kernels        : RoomKernels
    private let framePipelines : (centred: MTLComputePipelineState, leaning: MTLComputePipelineState)?
    private var scene          : Scene?
    private var denoiserRequest: (any RoomDenoiserInterest)?

    /// A RoomDenoiserPool other than the shared one, which a test gives a room to keep it apart from the rest.
    var denoiserPool: AnyObject?

    /// Schedules a refinement through the view's render queue when its pending bucket becomes ready.
    var denoiserDidBecomeReady: (() -> Void)?

    /// The bucket to draw into, or nil while this room must keep full-resolution analytic shadows.
    var denoisedPixelSize: CGSize? {
        denoiserRequest?.isReady == true ? denoiserRequest?.size : nil
    }

    /// Prewarms the current layout before it reaches the render queue. A bucket change releases
    /// the old interest; completion of an obsolete request cannot schedule a new-size refinement.
    func prepareDenoiser(
        pixelSize: CGSize,
        camera   : RoomCamera
    ) {
        guard #available(macOS 26, *), denoises, camera == .tilted,
              pixelSize.width > 0, pixelSize.height > 0 else {
            releaseDenoiser()
            return
        }
        let bucket = RoomDenoiserPool.Bucket(
            deviceID: device.registryID,
            width   : Int(pixelSize.width),
            height  : Int(pixelSize.height)
        )
        if denoiserRequest?.size == bucket.size {
            (denoiserRequest as? RoomDenoiserPool.Request)?.prepare()
            return
        }
        releaseDenoiser()
        denoiserRequest = (denoiserPool as? RoomDenoiserPool ?? .shared).request(
            device : device,
            width  : bucket.width,
            height : bucket.height,
            onReady: { [weak self] in self?.denoiserDidBecomeReady?() }
        )
    }

    func releaseDenoiser() {
        denoiserRequest?.cancel()
        denoiserRequest = nil
    }

    /// Fails when the device has no ray tracing, gives no queue or a kernel cannot be loaded. It
    /// `denoises` when asked to and the burst's kernel loads.
    init?(
        device  : MTLDevice,
        denoises: Bool = false
    ) {
        guard
            device.supportsRaytracing,
            let queue   = device.makeCommandQueue(),
            let kernels = RoomKernels(
                verb: "trace",
                load: { name in
                    Self.pipeline(
                        named : name,
                        device: device
                    )
                }
            ),
            let resolve = Self.pipeline(
                named : "resolveRoom",
                device: device
            )
        else { return nil }
        self.device     = device
        commandQueue    = queue
        self.kernels    = kernels
        resolvePipeline = resolve
        if denoises,
           let centred = Self.pipeline(
               named : "traceTiltedRoomFrame",
               device: device
           ),
           let leaning = Self.pipeline(
               named : "traceTiltedLeaningRoomFrame",
               device: device
           ) {
            framePipelines = (centred, leaning)
        } else {
            framePipelines = nil
        }
        self.denoises   = framePipelines != nil
    }

    /// Whether rooms should be denoised on a device that `isSupported` by MetalFX's denoised
    /// upscaler: always, unless `override`, the value of `BRAUS_ROOM_DENOISE`, is `off`.
    nonisolated static func denoises(
        isSupported: Bool,
        override   : String?
    ) -> Bool {
        isSupported && override != "off"
    }

    /// Whether rooms should be denoised on `device`: never before macOS 26.
    static func denoises(
        for device: MTLDevice,
        override  : String?
    ) -> Bool {
        guard #available(macOS 26, *) else { return false }
        return denoises(
            isSupported: MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device),
            override   : override
        )
    }

    func encodeImages(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        base         : MTLTexture,
        light        : MTLTexture,
        screen       : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        prepareDenoiser(
            pixelSize: CGSize(
                width : base.width,
                height: base.height
            ),
            camera   : uniforms.camera
        )
        if #available(macOS 26, *),
           let request = denoiserRequest as? RoomDenoiserPool.Request,
           request.bucket.width == base.width,
           request.bucket.height == base.height,
           let denoiser = request.borrow() {
            encodeDenoised(
                uniforms,
                size         : size,
                denoiser     : denoiser,
                base         : base,
                light        : light,
                screen       : screen,
                commandBuffer: commandBuffer
            )
            commandBuffer.addCompletedHandler { _ in
                Task { @MainActor in request.giveBack(denoiser) }
            }
            return
        }
        guard
            let structure = structure(
                size         : size,
                occupant     : uniforms.hasOccupant ? uniforms.shape : nil,
                camera       : uniforms.camera,
                lean         : uniforms.lean,
                pose         : uniforms.pose,
                commandBuffer: commandBuffer
            ),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        encoder.setAccelerationStructure(
            structure,
            bufferIndex: 1
        )
        dispatch(
            kernels.pipeline(for: uniforms),
            uniforms: uniforms,
            size    : size,
            base    : base,
            light   : light,
            screen  : screen,
            encoder : encoder
        )
    }

    /// Encodes `frames` frames of the tilted room, each traced at `denoiser`'s input size with
    /// `samples` samples per pixel and then denoised, which leaves the images in `base`, `light` and,
    /// for a room with a screen, `screen`, of `denoiser`'s full size.
    @available(macOS 26, *)
    func encodeDenoised(
        _ uniforms   : RoomLightUniforms,
        size         : CGSize,
        denoiser     : RoomDenoiser,
        frames       : Int = RoomDenoiser.burst,
        samples      : Int = RoomDenoiser.samples,
        base         : MTLTexture,
        light        : MTLTexture,
        screen       : MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard
            let framePipelines,
            let structure = structure(
                size         : size,
                occupant     : uniforms.hasOccupant ? uniforms.shape : nil,
                camera       : .tilted,
                lean         : uniforms.lean,
                pose         : uniforms.pose,
                commandBuffer: commandBuffer
            )
        else { return }
        let framePipeline = uniforms.lean > 0 ? framePipelines.leaning : framePipelines.centred
        let camera        = RoomCamera.Perspective(
            size: size,
            lean: uniforms.lean
        )
        var packed = uniforms.packed(
            size      : size,
            pixelWidth: denoiser.inputWidth
        )
        for index in 0..<frames {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            var frame = denoiser.frame(
                index,
                samples: samples,
                camera : camera
            )
            encoder.setComputePipelineState(framePipeline)
            encoder.setTextures(
                denoiser.inputs,
                range: 0..<denoiser.inputs.count
            )
            encoder.setBytes(
                &packed,
                length: MemoryLayout<RoomLightUniforms.Packed>.stride,
                index : 0
            )
            encoder.setAccelerationStructure(
                structure,
                bufferIndex: 1
            )
            encoder.setBytes(
                &frame,
                length: MemoryLayout<RoomDenoiser.Frame>.stride,
                index : 2
            )
            encoder.dispatchThreads(
                MTLSize(
                    width : denoiser.inputWidth,
                    height: denoiser.inputHeight,
                    depth : 1
                ),
                threadsPerThreadgroup: MTLSize(
                    width : 8,
                    height: 8,
                    depth : 1
                )
            )
            encoder.endEncoding()
            denoiser.encode(
                frame        : index,
                camera       : camera,
                base         : base,
                light        : light,
                screen       : uniforms.hasFrontLight ? screen : nil,
                commandBuffer: commandBuffer
            )
            denoisedFrames += 1
        }
    }

    /// Scene is a built acceleration structure and the room it was built for, as seen by its camera,
    /// with its composition's lean and the standing body's pose.
    /// It keeps the build's descriptor, which holds the vertex buffers, and its scratch buffer until
    /// the next rebuild, so the GPU never reads a released buffer.
    private struct Scene {
        let size      : CGSize
        let occupant  : WorkerShape?
        let camera    : RoomCamera
        let lean      : Float
        let pose      : RoomLightUniforms.Pose
        let structure : MTLAccelerationStructure
        let descriptor: MTLPrimitiveAccelerationStructureDescriptor
        let scratch   : MTLBuffer
    }

    private static let coveRings      = 10
    private static let cornerSegments = 12

    /// The body's rings from its equator to the top of its bevel, and its outline's points per turn.
    private static let bevelRings    = 16
    private static let pointsPerTurn = 96

    /// The acceleration structure for the room, the shape of the worker in it, the camera, the
    /// composition's lean and the standing body's pose, encoding its build into `commandBuffer` when any
    /// changed, before the pass that traces it.
    private func structure(
        size         : CGSize,
        occupant     : WorkerShape?,
        camera       : RoomCamera,
        lean         : Float,
        pose         : RoomLightUniforms.Pose,
        commandBuffer: MTLCommandBuffer
    ) -> MTLAccelerationStructure? {
        if let scene, scene.size == size, scene.occupant == occupant, scene.camera == camera, scene.lean == lean,
           scene.pose == pose {
            return scene.structure
        }
        let perspective = camera == .tilted ? RoomCamera.Perspective(
            size: size,
            lean: lean
        ) : nil
        // Geometry 0 is the room and 1 the body, as RoomLight.metal expects.
        var geometries = [perspective.map(Self.tiltedRoom) ?? Self.room(size)]
        if let occupant, let perspective {
            geometries.append(Self.standingBody(
                perspective,
                outline: occupant.outline,
                pose   : pose
            ))
        } else if let occupant {
            geometries.append(Self.body(
                size,
                lean   : lean,
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
            camera    : camera,
            lean      : lean,
            pose      : pose,
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
        return surface(
            rings,
            centre: SIMD3(width / 2, height / 2, 0)
        )
    }

    /// The tilted view's room: tall walls that meet the floor in coves of the camera's fillet radius
    /// and each other in the room's rounded corners, on a footprint that reaches far past the window
    /// toward the camera, so the room shows open at the front. The rings follow the footprint from
    /// the walls' top down to the cove's top, then round the cove to the floor's edge.
    private static func tiltedRoom(_ perspective: RoomCamera.Perspective) -> [SIMD3<Float>] {
        let width   = Float(perspective.size.width)
        let depth   = Float(perspective.footprintDepth)
        let corner  = RoomLightUniforms.Shape(size: perspective.size).cornerRadius
        let fillet  = Float(perspective.fillet)
        let profile = [(inset: Float(0), z: Float(perspective.wallHeight))] + (0...coveRings).map { index in
            let angle = Float.pi / 2 * Float(index) / Float(coveRings)
            return (inset: fillet * (1 - cos(angle)), z: fillet * (1 - sin(angle)))
        }
        let rings = profile.map { step in
            outline(
                width : width,
                height: depth,
                inset : step.inset,
                radius: corner - step.inset,
                z     : step.z
            )
        }
        return surface(
            rings,
            centre: SIMD3(width / 2, depth / 2, 0)
        )
    }

    /// The tilted view's standing body, in points: its outline upright in the plane facing the camera,
    /// its centroid `bottom` sphere radii over the floor so it rests on its lowest point, the core
    /// thickened by the slab before and behind its middle with a band between, and grown from there
    /// along the bevel's quarter circle to a flat cap in front and behind. The dome is left out, as
    /// from above. Every point is then moved by `pose`, as RoomLight.metal moves the body it shades.
    private static func standingBody(
        _ perspective: RoomCamera.Perspective,
        outline      : ShapeOutline,
        pose         : RoomLightUniforms.Pose
    ) -> [SIMD3<Float>] {
        let radius = Double(RoomLightUniforms.Shape(
            size: perspective.size,
            lean: perspective.lean
        ).sphereRadius)
        let centre = SIMD3(perspective.bodyX, perspective.bodyDepth, outline.bottom * radius)
        let foot   = SIMD3(centre.x, centre.y, 0)
        func placed(_ point: SIMD3<Double>) -> SIMD3<Float> {
            SIMD3<Float>(pose.moved(
                point,
                foot: foot
            ))
        }
        let slab   = RoomCamera.slab(of: outline) * radius
        let corner = outline.corner * radius
        func ring(
            _ index: Int,
            front  : Bool
        ) -> [SIMD3<Float>] {
            let angle = Double.pi / 2 * Double(index) / Double(bevelRings)
            let depth = (front ? 1 : -1) * (slab + corner * sin(angle))
            return outline.points(
                growth       : outline.corner * cos(angle),
                pointsPerTurn: pointsPerTurn
            ).map { point in
                placed(SIMD3(centre.x + radius * point.x, centre.y + depth, centre.z - radius * point.y))
            }
        }
        var vertices = surface([
            ring(0, front: true),
            ring(0, front: false),
        ])
        for front in [true, false] {
            let cap = placed(SIMD3(centre.x, centre.y + (front ? 1 : -1) * (slab + corner), centre.z))
            vertices += surface(
                (0...bevelRings).map { ring($0, front: front) },
                centre: cap
            )
        }
        return vertices
    }

    /// The triangles that join each ring to the next, outer to inner, and close the innermost with a
    /// fan from `centre` when there is one.
    private static func surface(
        _ rings: [[SIMD3<Float>]],
        centre : SIMD3<Float>? = nil
    ) -> [SIMD3<Float>] {
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
        guard let centre, let inner = rings.last else { return vertices }
        for index in inner.indices {
            vertices += [centre, inner[index], inner[(index + 1) % inner.count]]
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

    /// The worker's body where a room of `size` leaning `lean` stands it, across the room
    /// (`RoomLightUniforms.Shape.bodyX`) and halfway down, in points: rings of its outline grown from
    /// the core along the bevel's quarter circle, from the equator to the core, mirrored below, and the
    /// core as a flat cap on top and bottom. The dome is left out, so the mesh lies inside the top the
    /// shader shades and no reflected ray starts inside it. For the circle it is a sphere.
    private static func body(
        _ size : CGSize,
        lean   : Float,
        outline: ShapeOutline
    ) -> [SIMD3<Float>] {
        let radius = Double(RoomLightUniforms.Shape(
            size: size,
            lean: lean
        ).sphereRadius)
        let centre = SIMD2(
            Double(RoomLightUniforms.Shape.bodyX(
                in  : size,
                lean: lean
            )),
            Double(size.height) / 2
        )
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
