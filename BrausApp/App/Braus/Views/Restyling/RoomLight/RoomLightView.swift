//
//  RoomLightView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit

/// RoomLightView shows one room lit by its worker, seen from above.
///
/// It renders only on demand: once when it appears or changes size, and once when `uniforms`
/// change. A render draws the room with its light at full strength and, for a light that pulses, a
/// cycle of frames with the light at the pulse's weights, each tone mapped after the light is added;
/// `pulseLayer` plays them over the drawable with a keyframe animation of its contents, so the
/// light, its bleed on the walls and its reflections on the sphere pulse together while the sphere's
/// body stays, at the cost of compositing only. Under Reduce Motion nothing pulses.
///
/// The brows belong to a `MascotFace` with `drawsBody` false placed over the sphere, a circle of 34%
/// of the room's short side at its centre.
final class RoomLightView: MTKView {

    /// What the room shows. Setting a different value draws the room once.
    var uniforms: RoomLightUniforms {
        didSet {
            guard uniforms != oldValue else { return }
            requestedRenders += 1
            needsDisplay      = true
        }
    }

    /// How many times a change of `uniforms` has asked for a render.
    private(set) var requestedRenders = 0

    /// How the light is computed on this GPU, after `BRAUS_ROOM_LIGHT`; nil when no renderer could
    /// load and the room stays empty.
    let path: LightingPath?

    /// The layer that plays the pulse's frames over the drawable, hidden while nothing pulses.
    let pulseLayer = CALayer()

    static let pulseKey = "pulse"

    /// Frames rendered per pulse cycle; Core Animation cross-fades between them.
    static let framesPerCycle = 12

    private let renderer: (any RoomRenderer)?

    /// Counts renders, so frames that finish after a newer render are dropped.
    private var renderCount = 0

    init(
        device  : MTLDevice,
        uniforms: RoomLightUniforms,
        frame   : CGRect = .zero
    ) {
        let wanted = LightingPath.choose(
            for     : device,
            override: ProcessInfo.processInfo.environment["BRAUS_ROOM_LIGHT"]
        )
        // A ray tracer that cannot load falls back to the precomputed light.
        let tracer: RayTracedRoomRenderer? = wanted == .rayTraced ? RayTracedRoomRenderer(device: device) : nil
        let precomputed = tracer == nil ? PrecomputedRoomRenderer(device: device) : nil
        renderer      = tracer ?? precomputed
        path          = tracer != nil ? .rayTraced : (precomputed != nil ? .precomputed : nil)
        self.uniforms = uniforms
        super.init(
            frame : frame,
            device: device
        )
        isPaused              = true
        enableSetNeedsDisplay = true
        // The kernels write the drawable's texture directly.
        framebufferOnly  = false
        colorPixelFormat = .bgra8Unorm
        colorspace       = CGColorSpace(name: CGColorSpace.sRGB)
        pulseLayer.isHidden        = true
        pulseLayer.contentsGravity = .resize
        layer?.addSublayer(pulseLayer)
    }

    required init(coder: NSCoder) { fatalError("RoomLightView is code-only") }

    override func layout() {
        super.layout()
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.frame    = bounds
        layer.cornerRadius  = CGFloat(RoomLightUniforms.Shape(size: bounds.size).cornerRadius)
        layer.cornerCurve   = .continuous
        layer.masksToBounds = true
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        stopPulse()
        guard
            let renderer,
            let drawable      = currentDrawable,
            let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return }
        let weights = Self.pulseWeights(
            for          : uniforms.status,
            reducesMotion: RestylingMotion.reducesMotion
        )
        let frames = weights.compactMap { _ in Self.frameTexture(like: drawable.texture) }
        let pulse  = frames.count == weights.count ? Array(zip(frames, weights)) : []
        renderer.encode(
            uniforms,
            size         : bounds.size,
            into         : [(drawable.texture, 1)] + pulse.map { (texture: $0.0, weight: $0.1) },
            commandBuffer: commandBuffer
        )
        commandBuffer.present(drawable)
        renderCount += 1
        if !pulse.isEmpty {
            let render = renderCount
            let status = uniforms.status
            let pulseFrames = pulse.map(\.0)
            commandBuffer.addCompletedHandler { @Sendable [weak self] _ in
                let images = pulseFrames.compactMap(Self.image(from:))
                Task { @MainActor in
                    self?.startPulse(
                        images,
                        status: status,
                        render: render
                    )
                }
            }
        }
        commandBuffer.commit()
    }

    /// The light's weight in each frame of one pulse cycle: the prototype's busy flicker or waiting
    /// breath sampled `framesPerCycle` times, or none when the light holds still.
    static func pulseWeights(
        for status   : WorkerStatus,
        reducesMotion: Bool
    ) -> [Float] {
        let keys: [(time: Float, weight: Float)]
        switch status {
        case .busy   : keys = [(0, 1), (0.4, 0.8), (0.55, 0.95), (1, 1)]
        case .waiting: keys = [(0, 1), (0.5, 0.55), (1, 1)]
        case .free, .off: return []
        }
        guard !reducesMotion else { return [] }
        return (0..<framesPerCycle).map { index in
            let time = Float(index) / Float(framesPerCycle)
            let next = keys.firstIndex { $0.time > time } ?? keys.count - 1
            let from = keys[next - 1]
            let to   = keys[next]
            let step = (time - from.time) / (to.time - from.time)
            // Ease in and out, as the prototype's keyframes.
            let eased = step * step * (3 - 2 * step)
            return from.weight + (to.weight - from.weight) * eased
        }
    }

    /// The animation that plays one pulse cycle of `frames` for `status`, looping, or nil when the
    /// status does not pulse.
    static func pulse(
        _ frames: [CGImage],
        for status: WorkerStatus
    ) -> CAKeyframeAnimation? {
        let cycle: Double
        switch status {
        case .busy   : cycle = RestylingTiming.roomFlicker
        case .waiting: cycle = RestylingTiming.waitingBreath
        case .free, .off: return nil
        }
        guard let first = frames.first else { return nil }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values          = frames + [first]
        animation.keyTimes        = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.calculationMode = .linear
        animation.duration        = cycle
        animation.repeatCount     = .infinity
        return animation
    }

    private func startPulse(
        _ images: [CGImage],
        status  : WorkerStatus,
        render  : Int
    ) {
        guard
            render == renderCount,
            let animation = Self.pulse(
                images,
                for: status
            )
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.contents = images.first
        pulseLayer.isHidden = false
        pulseLayer.add(
            animation,
            forKey: Self.pulseKey
        )
        CATransaction.commit()
    }

    private func stopPulse() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.removeAnimation(forKey: Self.pulseKey)
        pulseLayer.contents = nil
        pulseLayer.isHidden = true
        CATransaction.commit()
    }

    /// A frame the size of `texture` that the GPU writes and the CPU reads back.
    private static func frameTexture(like texture: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width      : texture.width,
            height     : texture.height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderWrite]
        descriptor.storageMode = .shared
        return texture.device.makeTexture(descriptor: descriptor)
    }

    /// The finished sRGB frame in `texture` as an image. Called once the GPU has finished with it.
    nonisolated private static func image(from texture: MTLTexture) -> CGImage? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](
            repeating: 0,
            count    : bytesPerRow * texture.height
        )
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from       : MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space    = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width            : texture.width,
            height           : texture.height,
            bitsPerComponent : 8,
            bitsPerPixel     : 32,
            bytesPerRow      : bytesPerRow,
            space            : space,
            bitmapInfo       : CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider         : provider,
            decode           : nil,
            shouldInterpolate: false,
            intent           : .defaultIntent
        )
    }
}
