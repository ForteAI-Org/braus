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
/// to a room with no image yet, renders fully at once: a cut, or with `changeFade` a cross-fade from
/// the image shown.
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
///
/// In a tilted room the body moves a little with its brows' loop (`RoomBodyMotion`), which
/// `bodyLink` brings: once a full render has landed, the room bakes each pose of the motion through
/// RoomRenderQueue, one per submission, with the light at full and, for a light that pulses, at its
/// dimmest, and `bodyLayer` plays them over the room's own frames on the loop's clock, the frame at
/// full light showing as much as the pulse has dimmed; the brows follow the face's shift. Every live
/// frame and full render stops it, so a resize shows the body at rest. None from above, in an empty
/// room, for a worker that is off, or under Reduce Motion. A room clipped to its worker's outline
/// (`silhouette`) moves the outline with the body.
///
/// In a tilted room with an image of its size, the worker leaving for the chat steps out instead of
/// vanishing, and steps back in when it returns (`RoomPassage`): the room bakes the passage's poses and
/// the empty room with the precomputed light at the pulse's present weights, keeping its image until
/// they land, plays them over it in `passageLayer`, draws its live frame beneath, and leaves the full
/// render until the passage and the plaque's swing are over. A return starts once the plaque has faded.
final class RoomLightView: MTKView, RoomRenderTarget {

    /// What the room shows. The worker leaving or coming back is drawn at once as a live frame and
    /// rendered fully after the plaque's swing; another change renders fully at once. During a resize
    /// every change is a live frame, and the resize's own wait leads to the full render.
    var uniforms: RoomLightUniforms {
        didSet {
            guard uniforms != oldValue else { return }
            stopPassage()
            prepareDenoiser()
            requestedRenders += 1
            renderRevision += 1
            hasPendingRender   = true
            hasPendingUniforms = true
            let isSelection = uniforms.hasOccupant != oldValue.hasOccupant
            guard lastRenderedSize != nil, isResizing || isSelection else {
                holdShownImage()
                enqueueRenderIfReady()
                return
            }
            if !isResizing, isSelection, startPassage(from: oldValue) { return }
            needsLiveFrame = true
            if !isResizing {
                scheduleSettle(after: Self.refineDelay)
            }
            RoomRenderQueue.shared.live(self)
        }
    }

    /// How long a change of uniforms that renders fully at once cross-fades from the image shown to the
    /// new one, or nil for a cut, as rooms change. Under Reduce Motion every change cuts.
    var changeFade: Double?

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

    /// Joins the room to the brows over the body it draws, whose loop the body moves with.
    weak var bodyLink: RoomBodyLink?

    /// The layer that plays the body's motion over the room's own frames, hidden while the body is
    /// still: the pose with the light at full over the pose with the light at the pulse's dimmest.
    let bodyLayer = CALayer()
    let bodyLit   = CALayer()
    let bodyDim   = CALayer()

    static let bodyKey = "body"

    /// The body's pose as it showed when an action changed, fading out over the new motion.
    let bodyFade = CALayer()

    /// The motion the room plays, or bakes frames for.
    private(set) var bodyMotion: RoomBodyMotion?

    /// The frames baked so far for the room's current image, by pose: the light at full, then, for a
    /// light that pulses, at its dimmest.
    private(set) var bodyFrames: [RoomLightUniforms.Pose: [CGImage]] = [:]

    /// How many poses the room has baked.
    private(set) var bodyRenders = 0

    /// The render whose image `bodyFrames` match, once it has landed.
    private var bodyRevision: Int?

    /// The outline that clips the room to its worker, in the view's points with y down as SwiftUI
    /// draws it, or nil to show the whole room. It moves with the body.
    var silhouette: CGPath? {
        didSet {
            guard silhouette != oldValue else { return }
            needsLayout = true
        }
    }

    /// The mask that holds `silhouette`, the body's motion moving it.
    private(set) var bodyMask: CAShapeLayer?

    /// The layers that play the worker's passage out of its room or back in, over the room's own
    /// frames and the body's: the empty room, and over it the worker at the passage's poses, fading.
    let passageLayer  = CALayer()
    let passageEmpty  = CALayer()
    let passageWorker = CALayer()

    static let passageKey     = "passage"
    static let passageFadeKey = "passage.fade"

    /// The passage baking or playing; a newer one, or any change of the room's image, ends it.
    private(set) var passage: RoomPassage?

    /// How many passages have had their frames baked.
    private(set) var passageRenders = 0

    /// Tells a passage's frames landing late from the passage still wanted.
    private var passageID = 0

    /// Over `passageEmpty` and `passageWorker`, the same frames at full light where those hold the
    /// pulse's dimmest, showing as much as the pulse stood at when the passage started.
    let passageEmptyLit  = CALayer()
    let passageWorkerLit = CALayer()

    /// The body's image cut out along its outline, which steps out on Core Animation alone while the
    /// passage's frames are not ready yet.
    let passageSnapshot = CALayer()

    /// PassageFrames is the passage baked ahead, for the room with its worker in (`occupied`) at `size`:
    /// each pose of the way out, and the empty room, at full light and, for a light that pulses, at
    /// its dimmest.
    struct PassageFrames {
        let occupied: RoomLightUniforms
        let size    : CGSize
        let poses   : [RoomLightUniforms.Pose: [CGImage]]
        let empty   : [CGImage]
    }

    /// The passage baked once the room is at rest, so a choice of its worker plays at once.
    private(set) var passageFrames: PassageFrames?

    private let renderer: (any RoomRenderer)?

    /// The precomputed light drawn first after a resize when `renderer` is the ray tracer; nil
    /// when the renderer is already the precomputed one.
    private let previewRenderer: PrecomputedRoomRenderer?

    /// The precomputed light that draws live frames: the preview renderer, or the room's own renderer
    /// when that is already the precomputed one.
    private var liveRenderer: PrecomputedRoomRenderer? {
        previewRenderer ?? renderer as? PrecomputedRoomRenderer
    }

    /// Shows the preview over the refinement while the ray tracer works, then fades it out; and, with
    /// `changeFade`, the image shown before a change over the change's render.
    let refineLayer = CALayer()

    /// The preview's image, kept for `refineLayer`; nil until the preview has completed. With
    /// `changeFade`, it holds `shownImage` while a change renders.
    private var previewImage: CGImage?

    /// The last full render at full strength, read back while `changeFade` is set, and in a tilted room
    /// with its worker in, whose body steps out from it when no passage is baked yet.
    private(set) var shownImage: CGImage?

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

    static let fadeKey = "fade"

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
        // Nothing of the body's frames shows before its motion begins.
        bodyLayer.isHidden = true
        bodyLayer.opacity  = 0
        for frame in [bodyDim, bodyLit] {
            frame.contentsGravity = .resize
            bodyLayer.addSublayer(frame)
        }
        layer?.addSublayer(bodyLayer)
        bodyFade.isHidden        = true
        bodyFade.contentsGravity = .resize
        layer?.addSublayer(bodyFade)
        refineLayer.isHidden        = true
        refineLayer.contentsGravity = .resize
        layer?.addSublayer(refineLayer)
        // Over the refinement too: a passage covers the whole room while it plays.
        passageLayer.isHidden = true
        for frame in [passageEmpty, passageWorker, passageSnapshot] {
            frame.contentsGravity = .resize
            passageLayer.addSublayer(frame)
        }
        passageEmptyLit.contentsGravity  = .resize
        passageWorkerLit.contentsGravity = .resize
        passageEmpty.addSublayer(passageEmptyLit)
        passageWorker.addSublayer(passageWorkerLit)
        // The worker's envelope fades its two frames as one.
        passageWorker.allowsGroupOpacity = true
        passageSnapshot.anchorPoint      = .zero
        layer?.addSublayer(passageLayer)
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
        bodyLayer.frame     = bounds
        bodyDim.frame       = bounds
        bodyLit.frame       = bounds
        bodyFade.frame      = bounds
        passageLayer.frame  = bounds
        passageEmpty.frame  = bounds
        passageWorker.frame = bounds
        passageEmptyLit.frame  = bounds
        passageWorkerLit.frame = bounds
        applyMask()
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
            stopPassage()
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
        stopPassage()
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
                uniforms.screenStrength > 0 ? Self.screenWeight(
                    for          : uniforms.status,
                    reducesMotion: RestylingMotion.reducesMotion,
                    at           : lastLiveFrame
                ) : 1
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
        // A live frame or a preview replaces what a cross-fade would start from.
        shownImage            = nil
        stopPulse()
        stopBody()
        applyContentsRect()
        CATransaction.commit()
        return true
    }

    /// Asks for the live frame that arrived while a frame was in flight, then for a full render.
    private func continueAfterRender() {
        if needsLiveFrame { RoomRenderQueue.shared.live(self) }
        enqueueRenderIfReady()
    }

    /// Whether the full render, or a frame of the body's motion, may start: nothing is in flight and
    /// no size or uniforms are settling.
    var canRenderQueuedFrame: Bool {
        (hasPendingRender || needsBodyFrame || needsPassageFrames) && !isRendering && window != nil && renderer != nil
            && settleTask == nil
    }

    var renderPriority: (visible: Bool, uniforms: Bool, top: CGFloat) {
        (
            visible : !visibleRect.isEmpty && !isHiddenOrHasHiddenAncestor,
            uniforms: hasPendingUniforms,
            top     : convert(
                bounds,
                to: nil
            ).maxY
        )
    }

    private func enqueueRenderIfReady() {
        guard canRenderQueuedFrame else { return }
        RoomRenderQueue.shared.enqueue(self)
    }

    /// Uses MTKView's explicit draw entry point; the drawable comes straight from the layer, so it
    /// always has the size just asked for. RoomRenderQueue batches precomputed rooms and reserves a
    /// single slot for ray-traced refinements; each room still permits only one submission in flight.
    /// Returns false when newer geometry or a missing drawable prevented work from being submitted.
    /// With the full render done, it bakes the body's next pose instead.
    func renderQueuedFrame() -> Bool {
        guard canRenderQueuedFrame else { return false }
        guard hasPendingRender else {
            if needsBodyFrame { renderBodyFrame() } else { renderPassageFrames() }
            return isRendering
        }
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
            hasPendingRender,
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
        bodyFrames            = [:]
        bodyRevision          = nil
        let lamp    = Self.pulseWeights(
            for          : uniforms.status,
            reducesMotion: RestylingMotion.reducesMotion
        )
        // Only a screen varies; the capsule in its place holds still.
        let screen  = uniforms.screenStrength > 0 ? Self.screenWeights(
            for          : uniforms.status,
            reducesMotion: RestylingMotion.reducesMotion
        ) : []
        let weights = lamp.indices.map { SIMD2(lamp[$0], screen.indices.contains($0) ? screen[$0] : 1) }
        let frames  = weights.compactMap { _ in Self.frameTexture(like: drawable.texture) }
        let pulse   = frames.count == weights.count ? Array(zip(frames, weights)) : []
        let keepsFallback = (renderer as? RayTracedRoomRenderer).map {
            $0.denoises && uniforms.camera == .tilted && $0.denoisedPixelSize == nil
        } ?? false
        let fallback = keepsFallback ? Self.frameTexture(like: drawable.texture) : nil
        let isStanding = uniforms.camera == .tilted && uniforms.hasOccupant
        let shown    = changeFade != nil || isStanding ? Self.frameTexture(like: drawable.texture) : nil
        let whole    = [fallback, shown].compactMap { $0 }
        renderer.encode(
            uniforms,
            size         : size,
            into         : [(drawable.texture, SIMD2(1, 1))] + pulse.map { (texture: $0.0, weight: $0.1) }
                + whole.map { (texture: $0, weight: SIMD2<Float>(1, 1)) },
            commandBuffer: commandBuffer
        )
        // A managed frame reaches the CPU only once the GPU's copy is synchronised.
        let readbacks = frames + whole
        if readbacks.contains(where: { $0.storageMode == .managed }),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            for frame in readbacks {
                blit.synchronize(resource: frame)
            }
            blit.endEncoding()
        }
        let render        = renderRevision
        let status        = uniforms.status
        let path          = path
        let pulseFrames   = pulse.map(\.0) + whole
        let pulseCount    = pulse.count
        let hasFallback   = fallback != nil
        let hasShown      = shown != nil
        let readbackCount = pulseFrames.count
        // The preview over this render is the image shown before a change, which fades for longer.
        let fade          = (previewImage === shownImage ? changeFade : nil) ?? Self.refineFade
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let readImages = buffer.status == .completed ? pulseFrames.compactMap(Self.image(from:)) : []
            let images = Array(readImages.prefix(pulseCount))
            let isRead = readImages.count == readbackCount
            let fallbackImage = hasFallback && isRead ? readImages[pulseCount] : nil
            let shownImage    = hasShown && isRead ? readImages.last : nil
            Task { @MainActor in
                defer { RoomRenderQueue.shared.didFinishRender(for: path) }
                guard let self else { return }
                self.isRendering = false
                if self.window != nil {
                    self.startPulse(
                        images,
                        status: status,
                        render: render
                    )
                }
                if refines, render == self.renderRevision { self.fadeOutRefinement(over: fade) }
                if render == self.renderRevision, let fallbackImage {
                    self.previewImage = fallbackImage
                    self.needsRefinement = true
                }
                if render == self.renderRevision, let shownImage { self.shownImage = shownImage }
                if render == self.renderRevision { self.bodyRevision = render }
                self.prepareBody()
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
        stopBody()
        stopPassage()
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
        bodyDim.contentsRect     = rect
        bodyLit.contentsRect     = rect
        bodyFade.contentsRect    = rect
    }

    /// Keeps the image shown over the room until the change's full render lands beneath it, and the
    /// render then fades it out over `changeFade`; nothing when changes cut or under Reduce Motion.
    private func holdShownImage() {
        guard
            changeFade != nil,
            !RestylingMotion.reducesMotion,
            let shownImage,
            lastRenderedSize == renderSize
        else { return }
        previewImage    = shownImage
        needsRefinement = true
    }

    /// Fades the preview out over the image now beneath it, in `duration` seconds.
    private func fadeOutRefinement(over duration: Double) {
        guard !refineLayer.isHidden else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue   = 0
        fade.duration  = duration
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
            forKey: Self.fadeKey
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
        return following(
            keyPath,
            values: weights.map(value),
            for   : status,
            in    : layer
        )
    }

    /// An animation of `keyPath` through `values`, one per frame of the pulse for `status`, looping on
    /// its cycle and phased to the host clock in `layer`'s time; nil when the light holds still.
    private static func following(
        _ keyPath : String,
        values    : [Any],
        for status: WorkerStatus,
        in layer  : CALayer
    ) -> CAKeyframeAnimation? {
        guard
            let first = values.first,
            let cycle = pulseCycle(for: status)
        else { return nil }
        let pulse = CAKeyframeAnimation(keyPath: keyPath)
        pulse.values          = values + [first]
        pulse.keyTimes        = (0...values.count).map { NSNumber(value: Double($0) / Double(values.count)) }
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

    // MARK: - The body's motion

    /// The body's motion for the brows' `loop` in a room showing `uniforms` at `size`: none from above,
    /// in an empty room, for a worker that is off, for a loop of another status, or under Reduce Motion.
    static func bodyMotion(
        for loop     : WorkerBehaviourLoop?,
        uniforms     : RoomLightUniforms,
        size         : CGSize,
        reducesMotion: Bool
    ) -> RoomBodyMotion? {
        guard
            let loop,
            !reducesMotion,
            uniforms.camera == .tilted,
            uniforms.hasOccupant,
            uniforms.status != .off,
            loop.status == uniforms.status
        else { return nil }
        return RoomBodyMotion(
            loop : loop,
            shape: uniforms.shape,
            size : size,
            lean : uniforms.lean
        )
    }

    /// The body's motion for `action` in a room showing `uniforms` at `size`, a loop of its own: none
    /// from above, in an empty room, for a worker that is off, or under Reduce Motion.
    static func bodyMotion(
        for action   : WorkerAction,
        uniforms     : RoomLightUniforms,
        size         : CGSize,
        reducesMotion: Bool
    ) -> RoomBodyMotion? {
        guard
            !reducesMotion,
            uniforms.camera == .tilted,
            uniforms.hasOccupant,
            uniforms.status != .off
        else { return nil }
        return RoomBodyMotion(
            intents    : [action.intent],
            duration   : action.duration,
            shape      : uniforms.shape,
            size       : size,
            lean       : uniforms.lean,
            opensAtRest: false
        )
    }

    /// For a light that pulses in a room showing `uniforms`, the lamp's and the screen's weights of a
    /// pose's dim frame, each at its lowest, and for each of the pulse's frames how much of the pose's
    /// frame at full light shows over it, along the line between the two; nil for a light that holds
    /// still or under Reduce Motion. Only a screen varies; a capsule in its place holds still.
    static func bodyBlend(
        for uniforms : RoomLightUniforms,
        reducesMotion: Bool
    ) -> (low: SIMD2<Float>, shares: [Float])? {
        let lamp   = pulseWeights(
            for          : uniforms.status,
            reducesMotion: reducesMotion
        )
        let screen = uniforms.screenStrength > 0 ? screenWeights(
            for          : uniforms.status,
            reducesMotion: reducesMotion
        ) : []
        let pairs  = lamp.indices.map { SIMD2(lamp[$0], screen.indices.contains($0) ? screen[$0] : 1) }
        guard let first = pairs.first else { return nil }
        let low    = pairs.reduce(first) { pointwiseMin($0, $1) }
        let span   = SIMD2<Float>(1, 1) - low
        let length = (span * span).sum()
        guard length > 0 else { return nil }
        // ponytail: a busy room's lamp and screen pulse apart and one line follows both within a few
        // hundredths; bake a third frame per pose if that ever shows.
        return (low, pairs.map { max(0, min(1, (($0 - low) * span).sum() / length)) })
    }

    /// Follows a new loop of the brows that `bodyLink` holds: the motion restarts on its clock. While
    /// the body takes an action the loop waits.
    func bodyLoopDidChange() {
        guard bodyLink?.action == nil else { return }
        stopBody()
        prepareBody()
    }

    /// Follows the body's new action, or its return to the loop: the present pose fades out over
    /// `actionFade` as the new motion starts beneath it, and the brows blend from where they show.
    func bodyActionDidChange() {
        let fades = bodyLayer.animation(forKey: Self.bodyKey) != nil && !RestylingMotion.reducesMotion
        let shown = bodyLit.presentation()?.contents
        let level = bodyLayer.presentation()?.opacity ?? 0
        let brows = bodyLink?.mascot?.bodyOffset
        stopBody()
        prepareBody()
        guard fades, let shown, level > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyFade.removeAllAnimations()
        bodyFade.isHidden     = false
        bodyFade.contents     = shown
        bodyFade.opacity      = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = level
        fade.toValue   = 0
        fade.duration  = Self.actionFade
        bodyFade.add(
            fade,
            forKey: Self.bodyKey
        )
        CATransaction.commit()
        if let brows { bodyLink?.mascot?.blendBody(from: brows, over: Self.actionFade) }
    }

    /// How long the body cross-fades from one action to the next.
    static let actionFade = 0.3

    /// Whether the body's motion still wants a pose baked for the room's current image.
    private var needsBodyFrame: Bool {
        guard bodyRevision == renderRevision else { return false }
        return bodyPoses.contains { bodyFrames[$0] == nil }
    }

    /// The poses the room bakes for its body: its motion's, and every action's where the body takes
    /// actions (`actionPoses`), so a change of action plays at once.
    private var bodyPoses: [RoomLightUniforms.Pose] {
        let poses = bodyMotion?.poses ?? []
        return poses + actionPoses.filter { !poses.contains($0) }
    }

    /// Every action's poses, for a body that takes actions, as the room's image was last prepared.
    private var actionPoses: [RoomLightUniforms.Pose] = []

    /// Plays the body's motion for the room's current image once every pose has its frames, or asks
    /// the queue to bake the next one; stops it when there is none.
    private func prepareBody() {
        let motion = bodyRevision == renderRevision ? lastRenderedSize.flatMap { size in
            bodyLink?.action.map {
                Self.bodyMotion(
                    for          : $0,
                    uniforms     : uniforms,
                    size         : size,
                    reducesMotion: RestylingMotion.reducesMotion
                )
            } ?? Self.bodyMotion(
                for          : bodyLink?.loop,
                uniforms     : uniforms,
                size         : size,
                reducesMotion: RestylingMotion.reducesMotion
            )
        } : nil
        if motion != bodyMotion {
            stopBody()
            bodyMotion = motion
        }
        actionPoses = []
        if bodyLink?.takesActions == true, bodyRevision == renderRevision, let size = lastRenderedSize {
            for action in WorkerAction.allCases {
                for pose in Self.bodyMotion(
                    for          : action,
                    uniforms     : uniforms,
                    size         : size,
                    reducesMotion: RestylingMotion.reducesMotion
                )?.poses ?? [] where !actionPoses.contains(pose) {
                    actionPoses.append(pose)
                }
            }
        }
        guard let motion else { return }
        guard motion.poses.allSatisfy({ bodyFrames[$0] != nil }) else {
            enqueueRenderIfReady()
            return
        }
        if bodyLayer.animation(forKey: Self.bodyKey) == nil { playBody(motion) }
    }

    /// Bakes the body's next pose still without frames with the room's own renderer, at the size and
    /// uniforms of its image: the light at full and, for a light that pulses, at its dimmest. Called by
    /// RoomRenderQueue once the full render has landed; plays the motion when it was the last.
    private func renderBodyFrame() {
        guard
            let pose   = bodyPoses.first(where: { bodyFrames[$0] == nil }),
            let renderer,
            let size      = lastRenderedSize,
            let pixelSize = lastRenderedPixelSize,
            let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return }
        let blend   = Self.bodyBlend(
            for          : uniforms,
            reducesMotion: RestylingMotion.reducesMotion
        )
        let weights = [SIMD2<Float>(1, 1)] + (blend.map { [$0.low] } ?? [])
        let frames  = weights.compactMap { _ in
            Self.frameTexture(
                width : Int(pixelSize.width),
                height: Int(pixelSize.height),
                device: commandBuffer.device
            )
        }
        guard frames.count == weights.count else { return }
        var posed  = uniforms
        posed.pose = pose
        renderer.encode(
            posed,
            size         : size,
            into         : zip(frames, weights).map { (texture: $0, weight: $1) },
            commandBuffer: commandBuffer
        )
        if frames.contains(where: { $0.storageMode == .managed }), let blit = commandBuffer.makeBlitCommandEncoder() {
            for frame in frames {
                blit.synchronize(resource: frame)
            }
            blit.endEncoding()
        }
        isRendering = true
        let render = renderRevision
        let path   = path
        let count  = frames.count
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let images = buffer.status == .completed ? frames.compactMap(Self.image(from:)) : []
            Task { @MainActor in
                defer { RoomRenderQueue.shared.didFinishRender(for: path) }
                guard let self else { return }
                self.isRendering = false
                if render == self.renderRevision, images.count == count {
                    self.bodyFrames[pose] = images
                    self.bodyRenders     += 1
                }
                self.prepareBody()
                self.continueAfterRender()
            }
        }
        commandBuffer.commit()
    }

    /// Plays `motion` over the room's own frames from the start of the brows' loop, the frame at full
    /// light following the pulse over the dim one, and moves the brows and the outline with it.
    private func playBody(_ motion: RoomBodyMotion) {
        let lit = motion.poses.compactMap { bodyFrames[$0]?.first }
        let dim = motion.poses.compactMap { bodyFrames[$0]?.dropFirst().first }
        guard lit.count == motion.poses.count, let link = bodyLink, link.action != nil || link.loop != nil else { return }
        // An action runs on its own clock from its start; the loop on the brows'.
        let start = link.action != nil ? link.actionStart : link.start
        let dims  = dim.count == lit.count
        let parts = [
            (bodyLayer, motion.envelope()),
            (bodyLit, motion.frames(lit)),
        ] + (dims ? [(bodyDim, motion.frames(dim))] : []) + (bodyMask.map { [($0, motion.outline())] } ?? [])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyLayer.isHidden = false
        bodyDim.isHidden   = !dims
        for (layer, animation) in parts {
            animation.beginTime = layer.convertTime(start, from: nil)
            layer.add(
                animation,
                forKey: Self.bodyKey
            )
        }
        if dims, let blend = Self.bodyBlend(
            for          : uniforms,
            reducesMotion: RestylingMotion.reducesMotion
        ), let share = Self.following(
            "opacity",
            values: blend.shares.map { NSNumber(value: $0) },
            for   : uniforms.status,
            in    : bodyLit
        ) {
            bodyLit.add(
                share,
                forKey: Self.pulseKey
            )
        }
        CATransaction.commit()
        link.mascot?.followBody(
            motion.browMotion(),
            from: start
        )
    }

    /// Leaves the body at rest in the room's own frames, and the brows and the outline on it.
    private func stopBody() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [bodyLayer, bodyLit, bodyDim] + (bodyMask.map { [$0] } ?? []) {
            layer.removeAnimation(forKey: Self.bodyKey)
        }
        bodyLit.removeAnimation(forKey: Self.pulseKey)
        bodyLayer.isHidden = true
        bodyFade.removeAllAnimations()
        bodyFade.contents  = nil
        bodyFade.isHidden  = true
        CATransaction.commit()
        bodyLink?.mascot?.followBody(nil)
    }

    // MARK: - The worker's passage

    /// Starts the worker's passage out of the room or back in, now that `uniforms` has emptied it or
    /// filled it again from `old`, and draws the live frame of the new room beneath it. With the passage
    /// baked ahead for this room (`passageFrames`) it plays at once, its frames blended at the pulse's
    /// present weight. Otherwise the room bakes them now with the precomputed light at that weight,
    /// and meanwhile a worker leaving steps out on Core Animation alone, its image cut out along its
    /// outline (`passageSnapshot`), until they land. The brows start at once, from the same moment.
    /// Returns false where no passage can play: from above, out of a window, or before the room has an
    /// image of its size.
    private func startPassage(from old: RoomLightUniforms) -> Bool {
        guard
            uniforms.camera == .tilted,
            window != nil,
            let precomputed = liveRenderer,
            let size        = renderSize,
            let pixelSize   = renderPixelSize,
            lastRenderedSize == size
        else { return false }
        let isLeaving = !uniforms.hasOccupant
        let occupied  = isLeaving ? old : uniforms
        let reduces   = RestylingMotion.reducesMotion
        let passage   = RoomPassage(
            isLeaving    : isLeaving,
            shape        : occupied.shape,
            size         : size,
            lean         : occupied.lean,
            reducesMotion: reduces
        )
        let now   = CACurrentMediaTime()
        let start = now + (isLeaving ? 0 : RestylingTiming.plaqueLeave)
        passageID += 1
        let id = passageID
        self.passage = passage
        stopBody()
        bodyLink?.mascot?.followPassage(
            passage,
            from: start
        )
        // The full render waits for the passage, then for the plaque's swing.
        scheduleSettle(after: .seconds(start - now + passage.duration) + Self.refineDelay)
        needsLiveFrame = true
        defer { RoomRenderQueue.shared.live(self) }

        if let baked = passageFrames, baked.occupied == Self.standing(occupied), baked.size == size {
            let frames = passage.poses.compactMap { baked.poses[$0] }
            if frames.count == passage.poses.count {
                playPassage(
                    passage,
                    frames: frames,
                    empty : baked.empty,
                    share : Self.bodyShare(
                        for: occupied,
                        at : now
                    ),
                    from  : start
                )
                return true
            }
        }
        if isLeaving {
            playSnapshot(
                passage,
                of  : occupied,
                size: size,
                from: start
            )
        }
        guard let commandBuffer = precomputed.commandQueue.makeCommandBuffer() else { return true }
        let weight = SIMD2(
            Self.pulseWeight(
                for          : uniforms.status,
                reducesMotion: reduces,
                at           : now
            ),
            // Only a screen varies; a capsule in its place holds still.
            occupied.screenStrength > 0 ? Self.screenWeight(
                for          : uniforms.status,
                reducesMotion: reduces,
                at           : now
            ) : 1
        )
        let rooms = passage.poses.map { pose -> RoomLightUniforms in
            var posed  = occupied
            posed.pose = pose
            return posed
        } + [isLeaving ? uniforms : old]
        let frames = rooms.compactMap { _ in
            Self.frameTexture(
                width : Int(pixelSize.width),
                height: Int(pixelSize.height),
                device: commandBuffer.device
            )
        }
        guard frames.count == rooms.count else { return true }
        for (room, frame) in zip(rooms, frames) {
            precomputed.encode(
                room,
                size         : size,
                into         : [(texture: frame, weight: weight)],
                commandBuffer: commandBuffer
            )
        }
        Self.synchronize(
            frames,
            in: commandBuffer
        )
        let count = frames.count
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let images = buffer.status == .completed ? frames.compactMap(Self.image(from:)) : []
            Task { @MainActor in
                guard let self, id == self.passageID, images.count == count, let empty = images.last else { return }
                self.playPassage(
                    passage,
                    frames: images.dropLast().map { [$0] },
                    empty : [empty],
                    share : nil,
                    from  : start
                )
            }
        }
        commandBuffer.commit()
        return true
    }

    /// Plays `passage` over the room from `start` on the host clock: per pose `frames`, the empty room
    /// `empty`, each at full light and, when given a second, at the pulse's dimmest, shown with `share`
    /// of the light at full over it. Once it is over the layer shows the room as the live frame beneath
    /// it does. It takes over from the snapshot stepping out meanwhile.
    private func playPassage(
        _ passage : RoomPassage,
        frames    : [[CGImage]],
        empty     : [CGImage],
        share     : Float?,
        from start: CFTimeInterval
    ) {
        let lit   = frames.compactMap(\.first)
        let dim   = frames.compactMap { $0.dropFirst().first }
        let dims  = dim.count == lit.count && empty.count > 1
        let begin = passageWorker.convertTime(start, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        passageSnapshot.removeAllAnimations()
        passageSnapshot.isHidden    = true
        passageLayer.isHidden       = false
        // With two frames the dim one lies beneath; with one it is the only one.
        passageEmpty.contents       = dims ? empty.last : empty.first
        passageEmptyLit.contents    = dims ? empty.first : nil
        passageEmptyLit.isHidden    = !dims
        passageWorkerLit.isHidden   = !dims
        passageEmptyLit.opacity     = share ?? 1
        passageWorkerLit.opacity    = share ?? 1
        passageWorker.contents      = passage.isLeaving ? nil : (dims ? dim : lit).first
        passageWorkerLit.contents   = passage.isLeaving ? nil : lit.first
        passageWorker.opacity       = passage.isLeaving ? 0 : 1
        var parts = [
            (passageWorker as CALayer, Self.passageKey, passage.frames(dims ? dim : lit)),
            (passageWorker, Self.passageFadeKey, passage.envelope()),
        ]
        if dims { parts.append((passageWorkerLit, Self.passageKey, passage.frames(lit))) }
        for (layer, key, animation) in parts {
            animation.beginTime = begin
            layer.add(
                animation,
                forKey: key
            )
        }
        CATransaction.commit()
        passageRenders += 1
    }

    /// Steps the body of `occupied` out of the room on Core Animation alone, from `start`: its last
    /// full image cut out along its outline, carried and faded as the passage's poses carry it, over
    /// the empty room the live frame draws beneath. Nothing without that image.
    private func playSnapshot(
        _ passage: RoomPassage,
        of occupied: RoomLightUniforms,
        size     : CGSize,
        from start: CFTimeInterval
    ) {
        guard let shownImage else { return }
        let camera = RoomCamera.Perspective(
            size: size,
            lean: occupied.lean
        )
        let radius = Double(RoomLightUniforms.Shape(
            size: size,
            lean: occupied.lean
        ).sphereRadius)
        var flip = CGAffineTransform(
            a : 1,
            b : 0,
            c : 0,
            d : -1,
            tx: 0,
            ty: size.height
        )
        let mask  = CAShapeLayer()
        mask.frame = CGRect(
            origin: .zero,
            size  : size
        )
        mask.path  = camera.silhouette(of: occupied.shape).copy(using: &flip)
        let carry  = CAKeyframeAnimation(keyPath: "transform")
        carry.values = passage.keyframes.map { keyframe in
            NSValue(caTransform3D: CATransform3DMakeAffineTransform(RoomBodyMotion.outlineTransform(
                camera: camera,
                radius: radius,
                pose  : passage.poses[keyframe.pose]
            )))
        }
        let fade = passage.envelope()
        carry.keyTimes        = fade.keyTimes
        carry.calculationMode = .linear
        carry.duration        = passage.duration
        carry.fillMode        = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        passageLayer.isHidden     = false
        passageEmpty.contents     = nil
        passageEmptyLit.isHidden  = true
        passageWorker.contents    = nil
        passageWorkerLit.isHidden = true
        passageSnapshot.isHidden  = false
        passageSnapshot.frame     = bounds
        passageSnapshot.contents  = shownImage
        passageSnapshot.contentsRect = Self.contentsRect(
            rendered    : lastRenderedSize,
            bounds      : bounds.size,
            renderedLean: lastRenderedLean,
            lean        : uniforms.lean
        )
        passageSnapshot.mask    = mask
        passageSnapshot.opacity = 0
        for (key, animation) in [(Self.passageKey, carry as CAKeyframeAnimation), (Self.passageFadeKey, fade)] {
            animation.beginTime = passageSnapshot.convertTime(start, from: nil)
            passageSnapshot.add(
                animation,
                forKey: key
            )
        }
        CATransaction.commit()
    }

    /// Ends the passage, if any: the room shows its own frames again and the brows leave theirs.
    private func stopPassage() {
        passageID += 1
        guard passage != nil else { return }
        passage = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [passageWorker, passageWorkerLit, passageSnapshot] {
            layer.removeAllAnimations()
            layer.contents = nil
        }
        passageEmpty.contents    = nil
        passageEmptyLit.contents = nil
        passageSnapshot.mask     = nil
        passageLayer.isHidden    = true
        CATransaction.commit()
        bodyLink?.mascot?.followPassage(
            nil,
            from: 0
        )
    }

    /// `room` with its worker in and at rest, as the passage baked ahead is keyed.
    private static func standing(_ room: RoomLightUniforms) -> RoomLightUniforms {
        var standing         = room
        standing.hasOccupant = true
        standing.pose        = .rest
        return standing
    }

    /// Whether the passage still wants baking ahead for the room's present image: a tilted room whose
    /// full render has landed, its body's frames done, and no passage playing.
    private var needsPassageFrames: Bool {
        guard
            uniforms.camera == .tilted,
            passage == nil,
            bodyRevision == renderRevision,
            !needsBodyFrame,
            let size = lastRenderedSize
        else { return false }
        return passageFrames?.occupied != Self.standing(uniforms) || passageFrames?.size != size
    }

    /// Bakes the passage ahead with the precomputed light, for the room with its worker in: each pose
    /// of the way out, then the empty room, at full light and, for a light that pulses, at its dimmest.
    /// Called by RoomRenderQueue once the room is at rest.
    private func renderPassageFrames() {
        guard
            let precomputed   = liveRenderer,
            let size          = lastRenderedSize,
            let pixelSize     = renderPixelSize,
            let commandBuffer = precomputed.commandQueue.makeCommandBuffer()
        else { return }
        let occupied = Self.standing(uniforms)
        var empty    = occupied
        empty.hasOccupant = false
        let poses   = RoomPassage(
            isLeaving    : true,
            shape        : occupied.shape,
            size         : size,
            lean         : occupied.lean,
            reducesMotion: false
        ).poses
        let weights = [SIMD2<Float>(1, 1)] + (Self.bodyBlend(
            for          : occupied,
            reducesMotion: false
        ).map { [$0.low] } ?? [])
        let rooms   = poses.map { pose -> RoomLightUniforms in
            var posed  = occupied
            posed.pose = pose
            return posed
        } + [empty]
        let frames  = rooms.map { _ in
            weights.compactMap { _ in
                Self.frameTexture(
                    width : Int(pixelSize.width),
                    height: Int(pixelSize.height),
                    device: commandBuffer.device
                )
            }
        }
        guard frames.allSatisfy({ $0.count == weights.count }) else { return }
        for (room, targets) in zip(rooms, frames) {
            precomputed.encode(
                room,
                size         : size,
                into         : zip(targets, weights).map { (texture: $0, weight: $1) },
                commandBuffer: commandBuffer
            )
        }
        let all = frames.flatMap { $0 }
        Self.synchronize(
            all,
            in: commandBuffer
        )
        isRendering = true
        let render = renderRevision
        let path   = path
        let count  = all.count
        let each   = weights.count
        commandBuffer.addCompletedHandler { @Sendable [weak self] buffer in
            let images = buffer.status == .completed ? all.compactMap(Self.image(from:)) : []
            Task { @MainActor in
                defer { RoomRenderQueue.shared.didFinishRender(for: path) }
                guard let self else { return }
                self.isRendering = false
                if render == self.renderRevision, images.count == count {
                    let groups = stride(from: 0, to: count, by: each).map { Array(images[$0..<$0 + each]) }
                    self.passageFrames = PassageFrames(
                        occupied: occupied,
                        size    : size,
                        poses   : Dictionary(
                            zip(poses, groups.dropLast()),
                            uniquingKeysWith: { first, _ in first }
                        ),
                        empty   : groups.last ?? []
                    )
                }
                self.continueAfterRender()
            }
        }
        commandBuffer.commit()
    }

    /// For a light that pulses in a room showing `uniforms`, the share of a frame at full light over
    /// one at the pulse's dimmest that shows the pulse's weight at `hostTime`; nil when it holds still.
    static func bodyShare(
        for uniforms: RoomLightUniforms,
        at hostTime : CFTimeInterval
    ) -> Float? {
        let reduces = RestylingMotion.reducesMotion
        guard let blend = bodyBlend(
            for          : uniforms,
            reducesMotion: reduces
        ) else { return nil }
        let weight = SIMD2(
            pulseWeight(
                for          : uniforms.status,
                reducesMotion: reduces,
                at           : hostTime
            ),
            uniforms.screenStrength > 0 ? screenWeight(
                for          : uniforms.status,
                reducesMotion: reduces,
                at           : hostTime
            ) : 1
        )
        let span = SIMD2<Float>(1, 1) - blend.low
        return max(0, min(1, ((weight - blend.low) * span).sum() / (span * span).sum()))
    }

    /// Makes `frames` readable by the CPU once `commandBuffer` is done, where they are managed.
    private static func synchronize(
        _ frames: [MTLTexture],
        in commandBuffer: MTLCommandBuffer
    ) {
        guard frames.contains(where: { $0.storageMode == .managed }), let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        for frame in frames {
            blit.synchronize(resource: frame)
        }
        blit.endEncoding()
    }

    /// Clips the room to `silhouette`, turned into the layer's coordinates, y up; or shows it whole.
    private func applyMask() {
        guard let silhouette, let layer else {
            layer?.mask = nil
            bodyMask    = nil
            return
        }
        let mask = bodyMask ?? CAShapeLayer()
        mask.anchorPoint = .zero
        mask.frame       = bounds
        var flip = CGAffineTransform(
            a : 1,
            b : 0,
            c : 0,
            d : -1,
            tx: 0,
            ty: bounds.height
        )
        mask.path  = silhouette.copy(using: &flip)
        bodyMask   = mask
        layer.mask = mask
    }

    /// A frame the size of `texture` that the GPU writes and the CPU reads back.
    private static func frameTexture(like texture: MTLTexture) -> MTLTexture? {
        frameTexture(
            width : texture.width,
            height: texture.height,
            device: texture.device
        )
    }

    /// A frame of `width` by `height` pixels that the GPU writes and the CPU reads back.
    private static func frameTexture(
        width : Int,
        height: Int,
        device: MTLDevice
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width      : width,
            height     : height,
            mipmapped  : false
        )
        descriptor.usage       = [.shaderWrite]
        descriptor.storageMode = frameStorageMode(
            isAppleGPU      : device.supportsFamily(.apple1),
            hasUnifiedMemory: device.hasUnifiedMemory
        )
        return device.makeTexture(descriptor: descriptor)
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
