//
//  RoomLightView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit

/// RoomLightView shows one room lit by its worker, seen from above or through the tilted camera its
/// uniforms name (`RoomCamera`).
///
/// While the room is resized, every new size is drawn at once as a live frame: one precomputed frame
/// at the pulse's current weight, presented with the transaction that lays the size out, with the
/// pulse held. A room draws at most one live frame per display frame and has at most one in flight;
/// until it lands, the last image stays on screen scaled uniformly by the change of the room's short
/// side and placed on the worker (`contentsRect`), so the sphere keeps the size and centre the brows
/// follow. Once the size has been still for 70 milliseconds, a visible room on a ray-tracing GPU is
/// drawn at once with the precomputed light, then refined with the ray tracer through
/// RoomRenderQueue, the preview fading out over the refinement; only the refinement bakes the pulse.
///
/// The selection emptying the room, or its worker coming back, is drawn at once as a live frame too,
/// and the full render follows 0.9 seconds later, after the plaque's swing, so the frames that start
/// the swing carry neither ray tracing nor a pulse bake. Any other change of uniforms, and any change
/// to a room with no image yet, renders fully at once.
///
/// A render draws the room with its light at full strength and, for a light that pulses, a
/// cycle of frames with the light at the pulse's weights, each tone mapped after the light is added;
/// `pulseLayer` plays them over the drawable with a keyframe animation of its contents, so the
/// light, its bleed on the walls and its reflections on the sphere pulse together while the sphere's
/// body stays, at the cost of compositing only. Under Reduce Motion nothing pulses.
///
/// The brows belong to a `MascotFace` with `drawsBody` false and `catchesRoomLight` true placed over
/// the sphere, a circle of 40% of the room's short side at its centre, larger at the left when the
/// composition leans (`RoomLightUniforms.Shape`), or where the tilted camera shows the body's face;
/// every pulse is phased to the host clock, so the brows' tint pulses in step with the room.
final class RoomLightView: MTKView {

    /// What the room shows. The worker leaving or coming back is drawn at once as a live frame and
    /// rendered fully after the plaque's swing; another change renders fully at once. During a resize
    /// every change is a live frame, and the resize's own wait leads to the full render.
    var uniforms: RoomLightUniforms {
        didSet {
            guard uniforms != oldValue else { return }
            prepareDenoiser()
            requestedRenders += 1
            renderRevision += 1
            hasPendingRender   = true
            hasPendingUniforms = true
            let isSelection = uniforms.hasOccupant != oldValue.hasOccupant
            guard lastRenderedSize != nil, isResizing || isSelection else {
                enqueueRenderIfReady()
                return
            }
            needsLiveFrame = true
            if !isResizing {
                scheduleSettle(after: Self.refineDelay)
            }
            RoomRenderQueue.shared.live(self)
        }
    }

    /// How many times a change of `uniforms` has asked for a render.
    private(set) var requestedRenders = 0

    /// What the room has submitted to the GPU so far.
    private(set) var renderCounts = RenderCounts()

    /// Counts denoised submissions, so readiness tests can distinguish them from fallback renders.
    var denoisedFrames: Int { (renderer as? RayTracedRoomRenderer)?.denoisedFrames ?? 0 }

    /// RenderCounts counts a room's submissions by kind: live frames drawn while its size or uniforms
    /// change, previews of a settled size, and full renders by its renderer with the pulse baked.
    struct RenderCounts: Equatable {
        var live    = 0
        var preview = 0
        var full    = 0
    }

    /// How the light is computed on this GPU, after `BRAUS_ROOM_LIGHT`; nil when no renderer could
    /// load and the room stays empty.
    let path: LightingPath?

    /// The layer that plays the pulse's frames over the drawable, hidden while nothing pulses.
    let pulseLayer = CALayer()

    static let pulseKey = "pulse"

    /// Frames rendered per pulse cycle; Core Animation cross-fades between them.
    static let framesPerCycle = 12

    private let renderer: (any RoomRenderer)?

    /// The precomputed light drawn first after a resize when `renderer` is the ray tracer; nil
    /// when the renderer is already the precomputed one.
    private let previewRenderer: PrecomputedRoomRenderer?

    /// The precomputed light that draws live frames: the preview renderer, or the room's own renderer
    /// when that is already the precomputed one.
    private var liveRenderer: PrecomputedRoomRenderer? {
        previewRenderer ?? renderer as? PrecomputedRoomRenderer
    }

    /// Shows the preview over the refinement while the ray tracer works, then fades it out.
    private let refineLayer = CALayer()

    /// The preview's image, kept for `refineLayer`; nil until the preview has completed.
    private var previewImage: CGImage?

    /// Whether the drawable shows a preview the ray tracer has not replaced yet.
    private var needsRefinement = false

    /// Invalidates completions as soon as an input changes, before the next render begins.
    private var renderRevision = 0

    private var renderSize     : CGSize?
    private var renderPixelSize: CGSize?
    private var settleTask     : Task<Void, Never>?

    private var lastRenderedSize     : CGSize?
    private var lastRenderedPixelSize: CGSize?

    /// The lean the room's image was drawn with, which places its worker.
    private var lastRenderedLean: Float = 0

    /// The share of the drawable's width the room's image covers, below 1 after a live frame drawn
    /// into a wider drawable.
    private var drawableWidthShare: CGFloat = 1

    /// The pixels a live frame's drawable width moves in while resizing: 32 points at 2x.
    private static let liveWidthStep: CGFloat = 64

    private var hasPendingRender = false
    private var hasRenderPermit  = false

    /// Whether a submission is in flight, until its completion reaches the main actor. Waiting for
    /// that, not only for the GPU, keeps a room to one live frame per committed transaction, so its
    /// layer's few drawables are never all held at once.
    private var isRendering = false

    /// Whether the size changed since the last settled render, as opposed to only the uniforms.
    private var isResizing = false

    /// Whether the room shows another size or older uniforms than it has, and wants a live frame.
    private var needsLiveFrame = false

    /// When the last live frame started, which the next one keeps a display frame away from.
    private var lastLiveFrame: CFTimeInterval = 0

    private(set) var hasPendingUniforms = false

    private static let resizeDelay = Duration.milliseconds(70)

    /// How long a change of occupancy shows its live frame before the full render: about the plaque's
    /// swing, which the ray tracer's work and the pulse bake would otherwise interrupt.
    private static let refineDelay = Duration.milliseconds(900)

    /// How long the refinement takes to replace the preview.
    private static let refineFade = 0.15

    init(
        device  : MTLDevice,
        uniforms: RoomLightUniforms,
        frame   : CGRect = .zero
    ) {
        let environment = ProcessInfo.processInfo.environment
        let wanted      = LightingPath.choose(
            for     : device,
            override: environment["BRAUS_ROOM_LIGHT"]
        )
        // A ray tracer that cannot load falls back to the precomputed light.
        let tracer: RayTracedRoomRenderer? = wanted == .rayTraced ? RayTracedRoomRenderer(
            device  : device,
            denoises: RayTracedRoomRenderer.denoises(
                for     : device,
                override: environment["BRAUS_ROOM_DENOISE"]
            )
        ) : nil
        let precomputed = tracer == nil ? PrecomputedRoomRenderer(device: device) : nil
        renderer        = tracer ?? precomputed
        previewRenderer = tracer != nil ? PrecomputedRoomRenderer(device: device) : nil
        path            = tracer != nil ? .rayTraced : (precomputed != nil ? .precomputed : nil)
        self.uniforms = uniforms
        super.init(
            frame : frame,
            device: device
        )
        isPaused              = true
        enableSetNeedsDisplay = true
        // Layout scales the last drawable through `contentsRect`; only a render changes its pixel size.
        autoResizeDrawable    = false
        // The kernels write the drawable's texture directly.
        framebufferOnly  = false
        colorPixelFormat = .bgra8Unorm
        colorspace       = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.contentsGravity     = .resize
        pulseLayer.isHidden        = true
        pulseLayer.contentsGravity = .resize
        layer?.addSublayer(pulseLayer)
        refineLayer.isHidden        = true
        refineLayer.contentsGravity = .resize
        layer?.addSublayer(refineLayer)
        tracer?.denoiserDidBecomeReady = { [weak self] in
            guard let self, self.window != nil else { return }
            self.hasPendingRender = true
            self.enqueueRenderIfReady()
        }
    }

    required init(coder: NSCoder) { fatalError("RoomLightView is code-only") }

    override func layout() {
        super.layout()
        updateRenderSize()
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.frame    = bounds
        refineLayer.frame   = bounds
        applyContentsRect()
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
            (renderer as? RayTracedRoomRenderer)?.releaseDenoiser()
            RoomRenderQueue.shared.remove(self)
            settleTask?.cancel()
            settleTask      = nil
            isResizing      = false
            needsLiveFrame  = false
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
        prepareDenoiser()
        needsRefinement = false
        isResizing      = true
        needsLiveFrame  = true
        hideRefinement()
        scheduleSettle(after: Self.resizeDelay)
        RoomRenderQueue.shared.live(self)
    }

    /// Starts background preparation from layout, without waiting for the first full render.
    private func prepareDenoiser() {
        guard let renderPixelSize else { return }
        (renderer as? RayTracedRoomRenderer)?.prepareDenoiser(
            pixelSize: renderPixelSize,
            camera   : uniforms.camera
        )
    }

    /// Waits `delay` for the size or the uniforms to settle, then previews and refines the room, or
    /// renders it fully when its live frame already kept an image to refine. A newer change restarts
    /// the wait and cancels the room's queue slot.
    private func scheduleSettle(after delay: Duration) {
        renderRevision += 1
        hasPendingRender = true
        RoomRenderQueue.shared.remove(self)
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.isResizing = false
            if self.canPreview && !self.hasRefinablePreview {
                RoomRenderQueue.shared.preview(self)
            } else {
                self.enqueueRenderIfReady()
            }
        }
    }

    /// Whether the room shows a precomputed image of its current size that the ray tracer can refine.
    private var hasRefinablePreview: Bool {
        needsRefinement && previewImage != nil && lastRenderedSize == renderSize
    }

    /// Whether a settled size can be shown at once with the precomputed light: the room is visible,
    /// idle, and its renderer is the ray tracer.
    var canPreview: Bool {
        previewRenderer != nil && !isRendering && settleTask == nil && window != nil
            && !visibleRect.isEmpty && !isHiddenOrHasHiddenAncestor
    }

    /// Draws the room at its settled size with the precomputed light and leaves the ray-traced
    /// refinement to RoomRenderQueue, which calls this for every room settled in the same frame inside
    /// one transaction. A room that cannot be previewed any more joins the queue directly.
    func renderPreview() {
        if !renderPreviewIfPossible() { enqueueRenderIfReady() }
    }

    private func renderPreviewIfPossible() -> Bool {
        guard canPreview else { return false }
        let render    = renderRevision
        let submitted = presentPrecomputed(
            weight    : SIMD2(1, 1),
            keepsImage: true
        ) { [weak self] image in
            guard let self else { return }
            if render == self.renderRevision { self.previewImage = image }
            self.continueAfterRender()
        }
        guard submitted else { return false }
        hasPendingRender     = true
        hasPendingUniforms   = false
        needsRefinement      = true
        previewImage         = nil
        renderCounts.preview += 1
        return true
    }

    /// The wait before the room's next live frame may start: zero when it may start now, nil when it
    /// wants none or cannot draw one. A room with a frame in flight answers nil and asks again when
    /// that frame completes.
    var liveFrameDelay: CFTimeInterval? {
        guard
            needsLiveFrame,
            !isRendering,
            lastRenderedSize != nil,
            liveRenderer != nil,
            let window,
            !visibleRect.isEmpty,
            !isHiddenOrHasHiddenAncestor
        else { return nil }
        // Display frames counted on the host clock, so a jittered step is not mistaken for a second one.
        let frame = window.screen?.minimumRefreshInterval ?? 1.0 / 60
        let now   = CACurrentMediaTime()
        let next  = ((lastLiveFrame / frame).rounded(.down) + 1) * frame
        return max(0, next - now)
    }

    /// Draws one frame at the room's current size and uniforms with the precomputed light at the
    /// pulse's current weight, and holds the pulse until the full render. While resizing it draws
    /// into a drawable whose width only changes in steps of `liveWidthStep`, since a new drawable size
    /// costs the layer a new set of drawables; during a change of uniforms on a ray-tracing GPU it
    /// keeps its image, which the refinement then fades out. Called by RoomRenderQueue when
    /// `liveFrameDelay` is zero.
    func renderLiveFrame() {
        needsLiveFrame = false
        lastLiveFrame  = CACurrentMediaTime()
        hideRefinement()
        let keepsImage = !isResizing && previewRenderer != nil
        let render     = renderRevision
        let submitted  = presentPrecomputed(
            weight    : SIMD2(
                Self.pulseWeight(
                    for          : uniforms.status,
                    reducesMotion: RestylingMotion.reducesMotion,
                    at           : lastLiveFrame
                ),
                Self.screenWeight(
                    for          : uniforms.status,
                    reducesMotion: RestylingMotion.reducesMotion,
                    at           : lastLiveFrame
                )
            ),
            keepsImage: keepsImage,
            widthStep : isResizing ? Self.liveWidthStep : 1
        ) { [weak self] image in
            guard let self else { return }
            if keepsImage, render == self.renderRevision { self.previewImage = image }
            self.continueAfterRender()
        }
        guard submitted else { return }
        needsRefinement   = keepsImage
        previewImage      = nil
        renderCounts.live += 1
    }

    /// Draws the room at its current size with the precomputed light at `weight`, the lamp's and the
    /// screen's, into a drawable of
    /// its pixel height and its pixel width rounded up to `widthStep`, the room at the leading edge
    /// and framed by `contentsRect` one pixel to one, presented with the transaction that frames it.
    /// `keepsImage`, for drawables of exactly the room's size, also reads the frame back;
    /// `completion` gets that image, or nil, on the main actor once the GPU is done. Returns false
    /// when nothing was submitted.
    private func presentPrecomputed(
        weight    : SIMD2<Float>,
        keepsImage: Bool,
        widthStep : CGFloat = 1,
        completion: @escaping @MainActor @Sendable (CGImage?) -> Void
    ) -> Bool {
        guard
            let precomputed = liveRenderer,
            let size      = renderSize,
            let pixelSize = renderPixelSize,
            size.width > 0,
            size.height > 0,
            pixelSize.width > 0,
            pixelSize.height > 0,
            let metalLayer = layer as? CAMetalLayer
        else { return false }
        // One whole number of pixels for the room's width, which the extent and the framing share.
        let roomWidth    = Int(pixelSize.width.rounded(.up))
        let drawableSize = CGSize(
            width : (CGFloat(roomWidth) / widthStep).rounded(.up) * widthStep,
            height: pixelSize.height
        )
        // MTKView's own drawableSize reaches the layer later, so its next drawable would keep the old size.
        metalLayer.drawableSize = drawableSize
        guard
            let drawable      = metalLayer.nextDrawable(),
            Self.drawable(drawable, fits: drawableSize),
            let commandBuffer = precomputed.commandQueue.makeCommandBuffer()
        else { return false }
        let copy = keepsImage && widthStep == 1 ? Self.frameTexture(like: drawable.texture) : nil
        precomputed.encode(
            uniforms,
            size         : size,
            into         : [(drawable.texture, weight)] + (copy.map { [(texture: $0, weight: weight)] } ?? []),
            extent       : MTLSize(
                width : roomWidth,
                height: Int(pixelSize.height),
                depth : 1
            ),
            commandBuffer: commandBuffer
        )
        if let copy, copy.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: copy)
            blit.endEncoding()
        }
        isRendering = true
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let image = buffer.status == .completed ? copy.flatMap(Self.image(from:)) : nil
            Task { @MainActor in
                self?.isRendering = false
                completion(image)
            }
        }
        // The new size reaches the screen with the contentsRect that frames it.
        metalLayer.presentsWithTransaction = true
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawable.present()
        lastRenderedSize      = size
        lastRenderedPixelSize = pixelSize
        lastRenderedLean      = uniforms.lean
        drawableWidthShare    = CGFloat(roomWidth) / drawableSize.width
        stopPulse()
        applyContentsRect()
        CATransaction.commit()
        return true
    }

    /// Asks for the live frame that arrived while a frame was in flight, then for a full render.
    private func continueAfterRender() {
        if needsLiveFrame { RoomRenderQueue.shared.live(self) }
        enqueueRenderIfReady()
    }

    /// Whether the full render may start: nothing is in flight and no size or uniforms are settling.
    var canRenderQueuedFrame: Bool {
        hasPendingRender && !isRendering && window != nil && renderer != nil && settleTask == nil
    }

    private func enqueueRenderIfReady() {
        guard canRenderQueuedFrame else { return }
        RoomRenderQueue.shared.enqueue(self)
    }

    /// Uses MTKView's explicit draw entry point; the drawable comes straight from the layer, so it
    /// always has the size just asked for. Called only by RoomRenderQueue after reserving its sole slot.
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
        guard
            canRenderQueuedFrame,
            let size      = renderSize,
            let pixelSize = renderPixelSize,
            size.width > 0,
            size.height > 0,
            pixelSize.width > 0,
            pixelSize.height > 0,
            let renderer,
            let metalLayer = layer as? CAMetalLayer
        else { return }
        // Both axes cover the same room geometry; contentsRect scales the bucket to the view.
        let outputSize = (renderer as? RayTracedRoomRenderer)?.denoisedPixelSize ?? pixelSize
        // MTKView's own drawableSize reaches the layer later, so its next drawable would keep the old size.
        metalLayer.drawableSize = outputSize
        guard
            let drawable      = metalLayer.nextDrawable(),
            Self.drawable(drawable, fits: outputSize),
            let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return }
        let refines      = needsRefinement && previewImage != nil && size == lastRenderedSize
        let resizesImage = size != lastRenderedSize || outputSize != lastRenderedPixelSize || drawableWidthShare != 1
        hasPendingRender      = false
        hasPendingUniforms    = false
        needsRefinement       = false
        isRendering           = true
        renderCounts.full    += 1
        let lamp    = Self.pulseWeights(
            for          : uniforms.status,
            reducesMotion: RestylingMotion.reducesMotion
        )
        let screen  = Self.screenWeights(
            for          : uniforms.status,
            reducesMotion: RestylingMotion.reducesMotion
        )
        let weights = lamp.indices.map { SIMD2(lamp[$0], screen.indices.contains($0) ? screen[$0] : 1) }
        let frames  = weights.compactMap { _ in Self.frameTexture(like: drawable.texture) }
        let pulse   = frames.count == weights.count ? Array(zip(frames, weights)) : []
        let keepsFallback = (renderer as? RayTracedRoomRenderer).map {
            $0.denoises && uniforms.camera == .tilted && $0.denoisedPixelSize == nil
        } ?? false
        let fallback = keepsFallback ? Self.frameTexture(like: drawable.texture) : nil
        renderer.encode(
            uniforms,
            size         : size,
            into         : [(drawable.texture, SIMD2(1, 1))] + pulse.map { (texture: $0.0, weight: $0.1) }
                + (fallback.map { [(texture: $0, weight: SIMD2<Float>(1, 1))] } ?? []),
            commandBuffer: commandBuffer
        )
        // A managed frame reaches the CPU only once the GPU's copy is synchronised.
        let readbacks = frames + (fallback.map { [$0] } ?? [])
        if readbacks.contains(where: { $0.storageMode == .managed }),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            for frame in readbacks {
                blit.synchronize(resource: frame)
            }
            blit.endEncoding()
        }
        let render        = renderRevision
        let status        = uniforms.status
        let pulseFrames   = pulse.map(\.0) + (fallback.map { [$0] } ?? [])
        let pulseCount    = pulse.count
        let hasFallback   = fallback != nil
        let readbackCount = pulseFrames.count
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let readImages = buffer.status == .completed ? pulseFrames.compactMap(Self.image(from:)) : []
            let images = Array(readImages.prefix(pulseCount))
            let fallbackImage = hasFallback && readImages.count == readbackCount ? readImages.last : nil
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
                if refines, render == self.renderRevision { self.fadeOutRefinement() }
                if render == self.renderRevision, let fallbackImage {
                    self.previewImage = fallbackImage
                    self.needsRefinement = true
                }
                self.continueAfterRender()
            }
        }
        // An image of a new size must reach the screen with the contentsRect that frames it; one of
        // the same size is presented as soon as the GPU has drawn it, without waiting here.
        metalLayer.presentsWithTransaction = resizesImage
        if !resizesImage { commandBuffer.present(drawable) }
        commandBuffer.commit()
        if resizesImage { commandBuffer.waitUntilScheduled() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if refines, let previewImage {
            // The preview stays in front until the ray-traced image is ready beneath it.
            refineLayer.removeAllAnimations()
            refineLayer.contents = previewImage
            refineLayer.opacity  = 1
            refineLayer.isHidden = false
        }
        if resizesImage { drawable.present() }
        lastRenderedSize      = size
        lastRenderedPixelSize = outputSize
        lastRenderedLean      = uniforms.lean
        drawableWidthShare    = 1
        stopPulse()
        applyContentsRect()
        CATransaction.commit()
    }

    /// Whether `drawable` has the pixel size the room is about to be rendered at; an image drawn for
    /// one size into a texture of another would reach the screen stretched.
    private static func drawable(
        _ drawable: CAMetalDrawable,
        fits size : CGSize
    ) -> Bool {
        drawable.texture.width == Int(size.width) && drawable.texture.height == Int(size.height)
    }

    /// The part of an image rendered at `rendered` points, its composition leaning `renderedLean`,
    /// that a room of `bounds` points leaning `lean` shows: the image scaled by the change of the
    /// short side, with its worker where the room now puts it (`RoomLightUniforms.Shape.bodyX`) and
    /// the rest centred, so its sphere, a share of the short side across, keeps the size and centre
    /// the brows follow. Outside the unit square Core Animation repeats the image's edge pixels.
    static func contentsRect(
        rendered    : CGSize?,
        bounds      : CGSize,
        renderedLean: Float = 0,
        lean        : Float = 0
    ) -> CGRect {
        let unit = CGRect(
            x     : 0,
            y     : 0,
            width : 1,
            height: 1
        )
        guard
            let rendered,
            rendered != bounds,
            rendered.width > 0,
            rendered.height > 0,
            bounds.width > 0,
            bounds.height > 0
        else { return unit }
        let scale  = min(bounds.width, bounds.height) / min(rendered.width, rendered.height)
        let width  = bounds.width / scale / rendered.width
        let height = bounds.height / scale / rendered.height
        // The worker's place in the image shows at its place in the room.
        let worker = RoomLightUniforms.Shape.bodyX(
            in  : rendered,
            lean: renderedLean
        ) / rendered.width
        let placed = RoomLightUniforms.Shape.bodyX(
            in  : bounds,
            lean: lean
        ) / scale / rendered.width
        return CGRect(
            x     : worker - placed,
            y     : (1 - height) / 2,
            width : width,
            height: height
        )
    }

    /// Frames the drawable, the pulse and the preview by the size they were rendered at, the
    /// drawable within the share of its width the image covers. Called inside a transaction with
    /// actions disabled.
    private func applyContentsRect() {
        let rect = Self.contentsRect(
            rendered    : lastRenderedSize,
            bounds      : bounds.size,
            renderedLean: lastRenderedLean,
            lean        : uniforms.lean
        )
        layer?.contentsRect = CGRect(
            x     : rect.minX * drawableWidthShare,
            y     : rect.minY,
            width : rect.width * drawableWidthShare,
            height: rect.height
        )
        pulseLayer.contentsRect  = rect
        refineLayer.contentsRect = rect
    }

    /// Fades the preview out over the ray-traced image now beneath it.
    private func fadeOutRefinement() {
        guard !refineLayer.isHidden else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue   = 0
        fade.duration  = Self.refineFade
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // A newer refinement shows the preview again at full opacity; leave that one alone.
            MainActor.assumeIsolated {
                if self?.refineLayer.opacity == 0 { self?.hideRefinement() }
            }
        }
        refineLayer.opacity = 0
        refineLayer.add(
            fade,
            forKey: "fade"
        )
        CATransaction.commit()
    }

    private func hideRefinement() {
        guard !refineLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refineLayer.removeAllAnimations()
        refineLayer.isHidden = true
        refineLayer.contents = nil
        CATransaction.commit()
    }

    /// The light's weight in each frame of one pulse cycle: the prototype's busy flicker or waiting
    /// breath sampled `framesPerCycle` times, or none when the light holds still.
    static func pulseWeights(
        for status   : WorkerStatus,
        reducesMotion: Bool
    ) -> [Float] {
        switch status {
        case .busy      : sampled([(0, 1), (0.4, 0.8), (0.55, 0.95), (1, 1)], reducesMotion: reducesMotion)
        case .waiting   : sampled([(0, 1), (0.5, 0.55), (1, 1)], reducesMotion: reducesMotion)
        case .free, .off: []
        }
    }

    /// The screen's weight in each frame of one pulse cycle, apart from the lamp's: small, slow changes,
    /// as of what a busy worker's screen shows; none for a worker with no screen or under Reduce Motion.
    static func screenWeights(
        for status   : WorkerStatus,
        reducesMotion: Bool
    ) -> [Float] {
        guard status == .busy else { return [] }
        return sampled(
            [(0, 1), (0.3, 0.88), (0.5, 0.96), (0.78, 0.84), (1, 1)],
            reducesMotion: reducesMotion
        )
    }

    /// The weight at the screen's place in the pulse at `hostTime`, as `pulseWeight` reads the lamp's.
    static func screenWeight(
        for status   : WorkerStatus,
        reducesMotion: Bool,
        at hostTime  : CFTimeInterval
    ) -> Float {
        weight(
            in    : screenWeights(
                for          : status,
                reducesMotion: reducesMotion
            ),
            status: status,
            at    : hostTime
        )
    }

    /// `keys`, weights at times in 0...1 of a cycle, sampled `framesPerCycle` times and eased between
    /// them, or none under Reduce Motion.
    private static func sampled(
        _ keys       : [(time: Float, weight: Float)],
        reducesMotion: Bool
    ) -> [Float] {
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

    /// The light's weight at `hostTime` in the pulse `pulseLayer` plays for `status`, between the
    /// frames of `pulseWeights` as its keyframe animation interpolates them; 1 for a light that holds
    /// still or under Reduce Motion.
    static func pulseWeight(
        for status   : WorkerStatus,
        reducesMotion: Bool,
        at hostTime  : CFTimeInterval
    ) -> Float {
        weight(
            in    : pulseWeights(
                for          : status,
                reducesMotion: reducesMotion
            ),
            status: status,
            at    : hostTime
        )
    }

    /// The weight at `hostTime` between the frames of `weights`, one cycle of the pulse for `status`, as
    /// a keyframe animation phased to the host clock interpolates them; 1 when there are none.
    private static func weight(
        in weights : [Float],
        status     : WorkerStatus,
        at hostTime: CFTimeInterval
    ) -> Float {
        guard let cycle = pulseCycle(for: status), !weights.isEmpty else { return 1 }
        let elapsed  = (hostTime - pulseBeginTime(in: nil)) / cycle
        let position = (elapsed - elapsed.rounded(.down)) * Double(weights.count)
        let index    = min(weights.count - 1, Int(position))
        let next     = weights[(index + 1) % weights.count]
        let step     = Float(position - Double(index))
        return weights[index] + (next - weights[index]) * step
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

    /// An animation of `keyPath` through `value` at each of the pulse's weights for `status`, looping
    /// on its cycle and phased to the host clock in `layer`'s time, so whatever plays it pulses in step
    /// with the room's light; nil when the light holds still or under Reduce Motion.
    static func pulseFollowing(
        _ keyPath: String,
        for status: WorkerStatus,
        in layer  : CALayer,
        value     : (Float) -> Any
    ) -> CAKeyframeAnimation? {
        let weights = pulseWeights(
            for          : status,
            reducesMotion: RestylingMotion.reducesMotion
        )
        guard
            let first = weights.first,
            let cycle = pulseCycle(for: status)
        else { return nil }
        let pulse = CAKeyframeAnimation(keyPath: keyPath)
        pulse.values          = (weights + [first]).map(value)
        pulse.keyTimes        = (0...weights.count).map { NSNumber(value: Double($0) / Double(weights.count)) }
        pulse.calculationMode = .linear
        pulse.duration        = cycle
        pulse.repeatCount     = .infinity
        pulse.beginTime       = pulseBeginTime(in: layer)
        return pulse
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
