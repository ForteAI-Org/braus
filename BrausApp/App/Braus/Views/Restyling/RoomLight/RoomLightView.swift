//
//  RoomLightView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit

/// RoomLightView shows one room lit by its worker, seen from above.
///
/// Size changes settle for 150 milliseconds, then RoomRenderQueue spreads renders across frames.
/// Uniform changes enter the queue immediately; during resize they use the last rendered size.
/// Resizing alone stretches the last drawable and pulse frames without Metal work or CPU readback.
/// A render draws the room with its light at full strength and, for a light that pulses, a
/// cycle of frames with the light at the pulse's weights, each tone mapped after the light is added;
/// `pulseLayer` plays them over the drawable with a keyframe animation of its contents, so the
/// light, its bleed on the walls and its reflections on the sphere pulse together while the sphere's
/// body stays, at the cost of compositing only. Under Reduce Motion nothing pulses.
///
/// The brows belong to a `MascotFace` with `drawsBody` false and `catchesRoomLight` true placed over
/// the sphere, a circle of 34% of the room's short side at its centre; every pulse is phased to the
/// host clock, so the brows' tint pulses in step with the room.
final class RoomLightView: MTKView {

    /// What the room shows. Selection and status updates bypass the geometry debounce.
    var uniforms: RoomLightUniforms {
        didSet {
            guard uniforms != oldValue else { return }
            requestedRenders += 1
            renderRevision += 1
            hasPendingRender   = true
            hasPendingUniforms = true
            enqueueRenderIfReady()
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

    /// Invalidates completions as soon as an input changes, before the next render begins.
    private var renderRevision = 0

    private var renderSize     : CGSize?
    private var renderPixelSize: CGSize?
    private var settleTask     : Task<Void, Never>?

    private var lastRenderedSize     : CGSize?
    private var lastRenderedPixelSize: CGSize?

    private var hasPendingRender = false
    private var isRendering      = false
    private var hasRenderPermit  = false

    private(set) var hasPendingUniforms = false

    private static let resizeDelay = Duration.milliseconds(150)

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
        // Layout stretches the last drawable; only a settled render changes its pixel size.
        autoResizeDrawable    = false
        // The kernels write the drawable's texture directly.
        framebufferOnly  = false
        colorPixelFormat = .bgra8Unorm
        colorspace       = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.contentsGravity     = .resize
        pulseLayer.isHidden        = true
        pulseLayer.contentsGravity = .resize
        layer?.addSublayer(pulseLayer)
    }

    required init(coder: NSCoder) { fatalError("RoomLightView is code-only") }

    override func layout() {
        super.layout()
        updateRenderSize()
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.frame    = bounds
        layer.cornerRadius  = CGFloat(RoomLightUniforms.Shape(size: bounds.size).cornerRadius)
        layer.cornerCurve   = .continuous
        layer.masksToBounds = true
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            RoomRenderQueue.shared.remove(self)
            settleTask?.cancel()
            settleTask      = nil
            renderRevision += 1
            renderSize      = nil
            renderPixelSize = nil
        } else {
            updateRenderSize()
        }
    }

    /// Records geometry without resizing the drawable or disturbing the current pulse animation.
    private func updateRenderSize() {
        guard window != nil else { return }
        let size   = bounds.size
        let pixels = convertToBacking(bounds).size
        let pixelSize = CGSize(
            width : pixels.width.rounded(.up),
            height: pixels.height.rounded(.up)
        )
        guard size != renderSize || pixelSize != renderPixelSize else { return }
        renderSize      = size
        renderPixelSize = pixelSize
        scheduleSizeRender()
    }

    /// Debounces geometry only, cancelling its queue slot when another resize arrives.
    private func scheduleSizeRender() {
        renderRevision += 1
        hasPendingRender = true
        RoomRenderQueue.shared.remove(self)
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.resizeDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.enqueueRenderIfReady()
        }
        enqueueRenderIfReady()
    }

    /// Allows a uniform update at the previous size while the next geometry is still settling.
    var canRenderQueuedFrame: Bool {
        hasPendingRender && !isRendering && window != nil && renderer != nil
            && (settleTask == nil || (hasPendingUniforms && lastRenderedSize != nil))
    }

    private func enqueueRenderIfReady() {
        guard canRenderQueuedFrame else { return }
        RoomRenderQueue.shared.enqueue(self)
    }

    /// Uses MTKView's explicit draw entry point so it releases its drawable after the submission.
    /// Called only by RoomRenderQueue after reserving its sole slot.
    /// Returns false when newer geometry or a missing drawable prevented work from being submitted.
    func renderQueuedFrame() -> Bool {
        guard canRenderQueuedFrame else { return false }
        hasRenderPermit = true
        defer { hasRenderPermit = false }
        draw()
        return isRendering
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit can request display before layout, so check geometry before touching a drawable.
        updateRenderSize()
        guard hasRenderPermit else {
            enqueueRenderIfReady()
            return
        }
        let isSizeSettled = settleTask == nil
        guard
            canRenderQueuedFrame,
            let size      = isSizeSettled ? renderSize : lastRenderedSize,
            let pixelSize = isSizeSettled ? renderPixelSize : lastRenderedPixelSize,
            size.width > 0,
            size.height > 0,
            pixelSize.width > 0,
            pixelSize.height > 0,
            let renderer
        else { return }
        drawableSize = pixelSize
        guard
            let drawable      = currentDrawable,
            let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return }
        hasPendingRender      = !isSizeSettled
        hasPendingUniforms    = false
        isRendering           = true
        lastRenderedSize      = size
        lastRenderedPixelSize = pixelSize
        stopPulse()
        let weights = Self.pulseWeights(
            for          : uniforms.status,
            reducesMotion: RestylingMotion.reducesMotion
        )
        let frames = weights.compactMap { _ in Self.frameTexture(like: drawable.texture) }
        let pulse  = frames.count == weights.count ? Array(zip(frames, weights)) : []
        renderer.encode(
            uniforms,
            size         : size,
            into         : [(drawable.texture, 1)] + pulse.map { (texture: $0.0, weight: $0.1) },
            commandBuffer: commandBuffer
        )
        // A managed frame reaches the CPU only once the GPU's copy is synchronised.
        if frames.contains(where: { $0.storageMode == .managed }),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            for frame in frames {
                blit.synchronize(resource: frame)
            }
            blit.endEncoding()
        }
        commandBuffer.present(drawable)
        let render      = renderRevision
        let status      = uniforms.status
        let pulseFrames = pulse.map(\.0)
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let images = buffer.status == .completed ? pulseFrames.compactMap(Self.image(from:)) : []
            Task { @MainActor in
                defer { RoomRenderQueue.shared.didFinishRender() }
                guard let self else { return }
                self.isRendering = false
                if self.window != nil {
                    self.startPulse(
                        images,
                        status: status,
                        render: render
                    )
                }
                self.enqueueRenderIfReady()
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
        guard
            let cycle = pulseCycle(for: status),
            let first = frames.first
        else { return nil }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values          = frames + [first]
        animation.keyTimes        = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.calculationMode = .linear
        animation.duration        = cycle
        animation.repeatCount     = .infinity
        animation.beginTime       = pulseBeginTime(in: nil)
        return animation
    }

    /// The length of one pulse cycle for `status`, or nil when its light holds still.
    static func pulseCycle(for status: WorkerStatus) -> Double? {
        switch status {
        case .busy      : RestylingTiming.roomFlicker
        case .waiting   : RestylingTiming.waitingBreath
        case .free, .off: nil
        }
    }

    /// The begin time that phases every pulse to the host clock, in the time of `layer`, so the
    /// room's light and everything that follows it, like the brows, pulse in step whenever each was
    /// started. A layer whose time runs as the host's, the usual case, may pass nil.
    static func pulseBeginTime(in layer: CALayer?) -> CFTimeInterval {
        // Host time 1 lies in the past; zero would mean "now" to Core Animation.
        layer?.convertTime(1, from: nil) ?? 1
    }

    /// Where a pulse frame lives: shared memory on an Apple GPU, managed memory with a synchronising
    /// blit on Intel and AMD GPUs, which take no shared textures even when integrated and reporting
    /// unified memory.
    static func frameStorageMode(
        isAppleGPU      : Bool,
        hasUnifiedMemory: Bool
    ) -> MTLStorageMode {
        isAppleGPU && hasUnifiedMemory ? .shared : .managed
    }

    private func startPulse(
        _ images: [CGImage],
        status  : WorkerStatus,
        render  : Int
    ) {
        guard
            render == renderRevision,
            let animation = Self.pulse(
                images,
                for: status
            )
        else { return }
        animation.beginTime = Self.pulseBeginTime(in: pulseLayer)
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
        descriptor.storageMode = frameStorageMode(
            isAppleGPU      : texture.device.supportsFamily(.apple1),
            hasUnifiedMemory: texture.device.hasUnifiedMemory
        )
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
