//
//  CanvasHistory.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import PerceptionCore

/// CanvasHistory is what one window's canvases leave between observations: their tile hashes, the
/// noise each has learned, and their pixels in the last two observations, so a later request can be
/// answered with a canvas's crop before and after without any whole frame being kept.
///
/// One value follows one window: an observation of another window, or one without canvases, starts
/// it over. Each canvas region is copied into a bitmap of its own, so nothing else of a frame is
/// retained. A generation whose regions would take more than `maxGenerationBytes` is kept at fewer
/// pixels per point, so the value holds at most twice that; only a zoomed crop of such a canvas
/// loses detail.
///
/// Noise is learned only from frames with no Command between them: `learnIdle` hands such a frame
/// over between two observations, and an observation teaches only when no Command came since the
/// frame before it. Every time is an uptime in nanoseconds; an unknown time counts as input.
public struct CanvasHistory: Sendable {

    /// The most bytes one observation's canvas pixels are kept in.
    public static let maxGenerationBytes = 16 << 20

    /// What a request for a canvas's crop is answered with.
    public enum Answer: Sendable, Equatable {
        /// The crop of the changed area before and after, with its caption.
        case crop(CanvasCrop, caption: String)
        /// No unmasked tile of the canvas changed between the last two observations.
        case unchanged
        /// The crop would touch a secure or withheld field: no pixel may leave.
        case refused
        /// The canvas is not in both of the last two observations of this window.
        case unavailable
    }

    private struct Generation: Sendable {
        let scene     : SceneSnapshot
        let windowSize: CGSize
        let imageSize : CGSize
        let pictures  : [String: CanvasCrop.Source]
    }

    /// The window number the history follows; nil before its first observation.
    public private(set) var window: Int?
    private var tiles   : CanvasTiles?
    private var noises  : [String: CanvasNoise] = [:]
    private var previous: Generation?
    private var latest  : Generation?
    /// The changed tiles of each canvas from `previous` to `latest`, in window points.
    private var changed : [String: [CGRect]] = [:]
    /// When the last frame the noise saw was displayed.
    private var lastFrameAt: UInt64?

    public init() {}

    /// Whether the last observation held a canvas, so an idle frame is worth hashing.
    public var hasCanvases: Bool { tiles != nil }

    /// Whether the last observation names `id` as a canvas, independently of retained pixels.
    public func contains(_ id: String) -> Bool {
        latest?.scene.elements.contains { $0.id == id && $0.kind == .canvas } == true
    }

    /// The current whole canvas, reduced as a whole changed canvas is. Both crop pictures are the
    /// latest observation; a caller sends only `after`. No capture or observation is made here.
    public func current(
        _ id      : String,
        zoom      : Int = 1,
        isWithheld: (String) -> Bool
    ) throws(CanvasCrop.Failure) -> Answer {
        guard let latest, let source = latest.pictures[id],
              let canvas = latest.scene.elements.first(where: { $0.id == id && $0.kind == .canvas }),
              let layout = CanvasCrop.layout(
                  canvas : source.frame,
                  changed: [source.frame],
                  zoom   : zoom
              ) else { return .unavailable }
        guard let blanking = CanvasPrivacy.blanking(
            layout.rect,
            in        : latest.scene,
            windowSize: latest.windowSize,
            isWithheld: isWithheld
        ) else { return .refused }
        let crop = try CanvasCrop.make(
            before  : source,
            after   : source,
            layout  : layout,
            blanking: blanking
        )
        return .crop(
            crop,
            caption: CanvasCaption.text(
                of        : canvas,
                crop      : layout,
                in        : latest.scene,
                windowSize: latest.windowSize
            )
        )
    }

    /// Bytes of canvas pixels held for the last two observations.
    public var retainedBytes: Int {
        [previous, latest].compactMap { $0 }.reduce(0) { total, generation in
            generation.pictures.values.reduce(total) { $0 + $1.image.bytesPerRow * $1.image.height }
        }
    }

    /// The noise learned for the canvas `id`, as `CanvasTiles.mark` applies it.
    public func mask(of id: String) -> Set<Int> { noises[id]?.mask ?? [] }

    /// Marks the canvases of `scene`, read from `image` of window `window` (`windowSize` points,
    /// displayed at `displayedAt`), against the previous observation with the learned noise masked,
    /// then keeps their pixels for a later crop.
    public mutating func observe(
        _ scene      : inout SceneSnapshot,
        in image     : CGImage,
        window       : Int,
        windowSize   : CGSize,
        displayedAt  : UInt64?,
        lastCommandAt: UInt64?
    ) {
        if window != self.window {
            self = CanvasHistory()
            self.window = window
        }
        let hadInput = Self.hadInput(
            from         : lastFrameAt,
            to           : displayedAt,
            lastCommandAt: lastCommandAt
        )
        guard windowSize.width > 0, let next = CanvasTiles.mark(
            &scene,
            in      : image,
            since   : tiles,
            ignoring: noises.mapValues(\.mask)
        ) else {
            self = CanvasHistory()
            self.window = window
            return
        }
        var learned: [String: CanvasNoise] = [:]
        for (region, id) in next.ids.enumerated() {
            var noise = noises[id] ?? CanvasNoise()
            noise.observe(
                next.frame,
                region  : region,
                hadInput: hadInput
            )
            learned[id] = noise
        }
        let scale = CGFloat(image.width) / windowSize.width
        noises      = learned
        changed     = next.changedTiles.mapValues { $0.map { Self.points($0, scale: scale) } }
        previous    = latest
        latest      = Generation(
            scene     : scene,
            windowSize: windowSize,
            imageSize : CGSize(width: image.width, height: image.height),
            pictures  : Self.pictures(of: next, in: image, scale: scale)
        )
        tiles       = next
        lastFrameAt = displayedAt
    }

    /// Teaches each canvas's noise from `image`, a later frame of window `window` displayed at
    /// `displayedAt` that no observation read. It teaches only when no Command came since the last
    /// frame the noise saw; it is ignored for another window or another image size.
    public mutating func learnIdle(
        from image   : CGImage,
        window       : Int,
        displayedAt  : UInt64?,
        lastCommandAt: UInt64?
    ) {
        guard window == self.window, let tiles, let latest,
              CGSize(width: image.width, height: image.height) == latest.imageSize,
              let frame = RegionTileDiff.frame(
                  image,
                  regions  : tiles.frame.grids.map(\.region),
                  downscale: tiles.frame.downscale,
                  tile     : tiles.frame.tile
              ) else { return }
        let hadInput = Self.hadInput(
            from         : lastFrameAt,
            to           : displayedAt,
            lastCommandAt: lastCommandAt
        )
        for (region, id) in tiles.ids.enumerated() {
            noises[id]?.observe(
                frame,
                region  : region,
                hadInput: hadInput
            )
        }
        lastFrameAt = displayedAt
    }

    /// The crop of canvas `id` between the last two observations at `zoom` pixels per point, with
    /// `isWithheld` as the privacy policy (see `CanvasPrivacy`) over both observations' scenes.
    public func crop(
        _ id      : String,
        zoom      : Int = 1,
        isWithheld: (String) -> Bool
    ) throws(CanvasCrop.Failure) -> Answer {
        guard let previous, let latest,
              let before = previous.pictures[id], let after = latest.pictures[id],
              let changed = changed[id],
              let canvas = latest.scene.elements.first(where: { $0.id == id && $0.kind == .canvas })
        else { return .unavailable }
        guard let layout = CanvasCrop.layout(
            canvas : after.frame,
            changed: changed,
            zoom   : zoom
        ) else { return .unchanged }
        var blanking: [CGRect] = []
        for generation in [previous, latest] {
            guard let blanks = CanvasPrivacy.blanking(
                layout.rect,
                in        : generation.scene,
                windowSize: generation.windowSize,
                isWithheld: isWithheld
            ) else { return .refused }
            blanking += blanks
        }
        let crop = try CanvasCrop.make(
            before  : before,
            after   : after,
            layout  : layout,
            blanking: blanking
        )
        return .crop(
            crop,
            caption: CanvasCaption.text(
                of        : canvas,
                crop      : layout,
                in        : latest.scene,
                windowSize: latest.windowSize
            )
        )
    }

    /// Whether a Command may have reached the window between a frame displayed at `earlier` and one
    /// displayed at `later`. Frames of unknown time or order count as having had input.
    static func hadInput(
        from earlier : UInt64?,
        to later     : UInt64?,
        lastCommandAt: UInt64?
    ) -> Bool {
        guard let earlier, let later, later >= earlier else { return true }
        guard let lastCommandAt else { return false }
        return lastCommandAt >= earlier
    }

    private static func points(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x     : rect.minX / scale,
            y     : rect.minY / scale,
            width : rect.width / scale,
            height: rect.height / scale
        )
    }

    /// Copies each canvas region of `image` into its own bitmap, reduced together when they would
    /// exceed `maxGenerationBytes`. The copy keeps the frame's colour space and layout when a bitmap can
    /// hold them, so it is a plain copy; colours are converted only for a crop. A region that cannot be
    /// copied is left out, so its crop is unavailable.
    private static func pictures(
        of tiles: CanvasTiles,
        in image: CGImage,
        scale   : CGFloat
    ) -> [String: CanvasCrop.Source] {
        let regions = tiles.frame.grids.map(\.region)
        let bytes = regions.reduce(0) { $0 + $1.width * $1.height * 4 }
        let reduction = bytes > CGFloat(maxGenerationBytes) ? (CGFloat(maxGenerationBytes) / bytes).squareRoot() : 1
        var pictures: [String: CanvasCrop.Source] = [:]
        for (id, region) in zip(tiles.ids, regions) {
            let width  = max(1, Int(region.width * reduction))
            let height = max(1, Int(region.height * reduction))
            guard let part = image.cropping(to: region),
                  let context = bitmap(width: width, height: height, like: image) else { continue }
            context.interpolationQuality = reduction < 1 ? .high : .none
            context.draw(
                part,
                in: CGRect(
                    x     : 0,
                    y     : 0,
                    width : width,
                    height: height
                )
            )
            guard let copy = context.makeImage() else { continue }
            // Unpadded rows keep the copy within the bound it was reduced to.
            assert(copy.bytesPerRow == width * 4)
            pictures[id] = CanvasCrop.Source(
                image : copy,
                origin: CGPoint(
                    x: region.minX / scale,
                    y: region.minY / scale
                ),
                scale : CGFloat(width) * scale / region.width
            )
        }
        return pictures
    }

    /// An unpadded 8-bit, 4-byte bitmap in `image`'s colour space and layout, else in sRGB RGBA.
    private static func bitmap(width: Int, height: Int, like image: CGImage) -> CGContext? {
        func context(_ space: CGColorSpace?, _ info: UInt32) -> CGContext? {
            guard let space else { return nil }
            return CGContext(
                data            : nil,
                width           : width,
                height          : height,
                bitsPerComponent: 8,
                bytesPerRow     : width * 4,
                space           : space,
                bitmapInfo      : info
            )
        }
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.colorSpace?.model == .rgb,
           let same = context(image.colorSpace, image.bitmapInfo.rawValue) {
            return same
        }
        return context(CGColorSpace(name: CGColorSpace.sRGB), CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
