//
//  ScenePipeline.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif

/// ScenePipeline builds a text scene from one window image: text runs from a recognizer, region
/// boxes from a segmenter, grouped into elements, composed into named panels, hashed into a token.
///
/// Every dependency arrives at construction. The pipeline reads no environment, keeps no global,
/// and remembers nothing between calls, so two pipelines never couple and a test drives one with
/// doubles. Recognition, icon segmentation and native reads run concurrently; section detection
/// then receives text bounds. CPU work runs off the caller's actor, including AppKit's main actor.
/// Accessibility is an optional augmentation stage taken at construction: pixels build the whole
/// scene, and the stage only adds. Control state reading is a second optional stage of the same
/// shape, asked last so an application that answered for itself always wins. The remaining stages
/// (taught icon labels, learned structure) are later roles, absent here on purpose rather than
/// defaulted to a silent no-op.
public struct ScenePipeline: Sendable {

    /// Stage durations are independent elapsed intervals. OCR, segmentation and AX overlap.
    /// The hook runs on the stage's executor, including on failure; consumers must synchronize it.
    public enum Stage: String, CaseIterable, Sendable {
        case visionInitialization = "Vision init"
        case pipelineInitialization = "pipeline init (includes Vision)"
        case ocr = "OCR"
        case regions = "segmentation"
        case mediaFilter = "media filter"
        case sections
        case sceneBuilding = "scene building"
        case augmentation = "AX"
        case merge
        case controlState = "control state"
    }

    public typealias TimingHook = @Sendable (Stage, Duration) -> Void

    private let timingHook: TimingHook?

    /// What the pipeline needs about the window besides its pixels.
    public struct Window: Sendable, Equatable {
        public var bundleID: String
        public var appName: String
        public var title: String
        /// Known menu paths to carry into the scene.
        public var commands: [String]
        /// Panel rectangles a section detector found, window-normalized. Empty composes no sections.
        public var sectionRects: [NormalizedRect]
        /// The window's owner and its frame in global points, needed by an augmentation stage to read
        /// the right tree and to judge its frames. Nil skips augmentation for this window.
        public var processID: pid_t?
        public var frame: CGRect?
        /// The actual captured recipient, when the capture adapter attests it.
        public var windowNumber: Int?
        /// Other surfaces drawn over this window, in global points. Its native tree cannot label their pixels.
        public var occludingFrames: [CGRect]

        public init(
            bundleID    : String,
            appName     : String,
            title       : String,
            commands    : [String] = [],
            sectionRects: [NormalizedRect] = [],
            processID   : pid_t? = nil,
            frame       : CGRect? = nil,
            windowNumber: Int? = nil,
            occludingFrames: [CGRect] = []
        ) {
            self.bundleID     = bundleID
            self.appName      = appName
            self.title        = title
            self.commands     = commands
            self.sectionRects = sectionRects
            self.processID    = processID
            self.frame        = frame
            self.windowNumber = windowNumber
            self.occludingFrames = occludingFrames
        }
    }

    private let text: any TextRecognizing
    private let regions: (any RegionSegmenting)?
    private let regionFilter: (any VisualRegionFiltering)?
    private let sections: (any SectionDetecting)?
    private let augmentation: (any SceneAugmenting)?
    private let controlState: (any ControlStateReading)?
    private let accuracy: TextRecognitionAccuracy

    /// Creates a pipeline over its roles. A nil region segmenter supplies no icon candidates. A nil
    /// region filter leaves media classification to the caller; otherwise filtering receives OCR
    /// barriers before grouping. A nil section detector uses only caller-provided panels. A nil
    /// augmenter leaves the pixel scene. A nil control state reader leaves every control whose
    /// state no application reported silent, which is what the scene said before the role existed.
    public init(
        text        : any TextRecognizing,
        regions     : (any RegionSegmenting)? = nil,
        regionFilter: (any VisualRegionFiltering)? = nil,
        sections    : (any SectionDetecting)? = nil,
        augmentation: (any SceneAugmenting)? = nil,
        controlState: (any ControlStateReading)? = nil,
        accuracy    : TextRecognitionAccuracy = .accurate,
        timingHook  : TimingHook? = nil
    ) {
        self.timingHook   = timingHook
        self.text         = text
        self.regions      = regions
        self.regionFilter = regionFilter
        self.sections     = sections
        self.augmentation = augmentation
        self.controlState = controlState
        self.accuracy     = accuracy
    }

    /// Perceives one image of one window. Throws when recognition or segmentation cannot run;
    /// an empty window is a scene with no elements, not an error. The scene of `capture`, for a
    /// caller that needs no quality.
    @concurrent
    public func perceive(_ image: CGImage, of window: Window) async throws -> SceneSnapshot {
        try await capture(image, of: window).scene
    }

    /// Perceives one image of one window and answers the scene with the quality of the
    /// accessibility read that contributed to it. The quality is the augmentation stage's own
    /// answer; when the stage is absent, or the window names no process and frame to read, no read
    /// took place and the quality is `unknown`, never a complete read that did not happen.
    @concurrent
    public func capture(_ image: CGImage, of window: Window) async throws -> SceneCapture {
        try await capture(image, of: window, reusing: nil).capture
    }

    /// Pixel-derived facts only. The caller may reuse them after proving equal pixels and window facts.
    package struct VisualScene: Sendable {
        fileprivate let scene: SceneSnapshot
        fileprivate let segments: [CGRect]
        fileprivate let window: Window
    }

    /// Reuses recognition while reading native facts again, including their current quality.
    @concurrent
    package func capture(
        _ image: CGImage, of window: Window, reusing visual: VisualScene?
    ) async throws -> (capture: SceneCapture, visual: VisualScene) {
        try Task.checkCancellation()
        #if BRAUS_PHASES
        async let harvested = PhaseInterval.measure("pipeline.ax") {
            try await measureAsync(.augmentation) { try await augmentationElements(for: window) }
        }
        #else
        async let harvested = measureAsync(.augmentation) { try await augmentationElements(for: window) }
        #endif
        let pixels: VisualScene
        if let visual, visual.window == window,
           visual.scene.viewportPixelSize == ViewportPixelSize(width: image.width, height: image.height) {
            pixels = visual
        } else {
            pixels = try await recognize(image, of: window)
        }
        #if BRAUS_PHASES
        let waiting = PhaseInterval.begin("pipeline.axWait")
        #endif
        let harvest = try await harvested
        #if BRAUS_PHASES
        waiting.end()
        let merging = PhaseInterval.begin("pipeline.merge")
        #endif
        try Task.checkCancellation()
        let merged = measure(.merge) { Self.augmented(pixels.scene, with: harvest).scene }
        #if BRAUS_PHASES
        merging.end()
        let stating = controlState == nil ? nil : PhaseInterval.begin("pipeline.controlState")
        defer { stating?.end() }
        #endif
        let scene = controlState.map { reader in
            measure(.controlState) { Self.stated(merged, from: image, segments: pixels.segments, reader: reader) }
        } ?? merged
        return (SceneCapture(scene: scene, quality: harvest.quality), pixels)
    }

    @concurrent
    private func recognize(_ image: CGImage, of window: Window) async throws -> VisualScene {
        let regions = self.regions, sections = self.sections
        #if BRAUS_PHASES
        async let recognized = PhaseInterval.measure("pipeline.ocr") {
            try await measureAsync(.ocr) { try await recognizeText(in: image, of: window) }
        }
        async let segmented = PhaseInterval.measure("pipeline.segments") {
            try await measureAsync(.regions) {
                try await AbandonableRead.run { try regions?.segments(in: image) ?? [] }
            }
        }
        #else
        async let recognized = measureAsync(.ocr) { try await recognizeText(in: image, of: window) }
        async let segmented = measureAsync(.regions) {
            try await AbandonableRead.run { try regions?.segments(in: image) ?? [] }
        }
        #endif
        let (runs, segments) = try await (recognized, segmented)
        try Task.checkCancellation()
        #if BRAUS_PHASES
        let composing = PhaseInterval.begin("pipeline.compose")
        #endif
        let visual = try measure(.mediaFilter) {
            try regionFilter?.filter(segments, in: image, protecting: runs.map(\.pixelBox))
                ?? VisualRegions(icons: segments)
        }
        try Task.checkCancellation()
        var composedWindow = window
        if composedWindow.sectionRects.isEmpty {
            let panels = try measure(.sections) {
                try sections?.sections(in: image, protecting: runs.map(\.pixelBox)) ?? []
            }
            let size = CGSize(width: image.width, height: image.height)
            composedWindow.sectionRects = panels.map { NormalizedRect(pixelBox: $0, in: size) }
        }
        let scene = measure(.sceneBuilding) {
            Self.assemble(
                runs     : runs,
                segments : visual.icons,
                imageSize: CGSize(width: image.width, height: image.height),
                window   : composedWindow,
                images   : visual.images,
                overlays : visual.overlays
            )
        }
        #if BRAUS_PHASES
        composing.end()
        #endif
        return VisualScene(scene: scene, segments: visual.icons, window: window)
    }

    private func measure<T>(_ stage: Stage, _ operation: () throws -> T) rethrows -> T {
        guard let timingHook else { return try operation() }
        let started = ContinuousClock.now
        defer { timingHook(stage, started.duration(to: .now)) }
        return try operation()
    }

    private func measureAsync<T: Sendable>(
        _ stage: Stage, _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        guard let timingHook else { return try await operation() }
        let started = ContinuousClock.now
        defer { timingHook(stage, started.duration(to: .now)) }
        return try await operation()
    }

    /// Asks the control state reader about every switch, checkbox and radio the grouper's candidate
    /// passes find in the same segments the scene was built from, and writes what it commits to onto
    /// the elements that still carry no state.
    ///
    /// Last on purpose, after augmentation: an element accessibility already spoke for is skipped, so
    /// pixels only ever fill a gap. A reading is claimed by the smallest stateless element it covers,
    /// and a reading no element covers is dropped rather than attached to the panel around it.
    private static func stated(
        _ scene  : SceneSnapshot,
        from image: CGImage,
        segments : [CGRect],
        reader   : any ControlStateReading
    ) -> SceneSnapshot {
        var readings: [(box: CGRect, state: ControlState)] = []
        for mark in ElementGrouper.markCandidates(segments: segments, isMarkShaped: reader.isMarkShaped) {
            guard let state = reader.state(of: ControlCandidate(box: mark, shape: .mark), in: image) else {
                continue
            }
            readings.append((mark, state))
        }
        // A confirmed mark leaves the switch pass's input: its dot would otherwise be read as a knob.
        let rest = segments.filter { segment in
            !readings.contains { $0.box.insetBy(dx: -1, dy: -1).contains(segment) }
        }
        for candidate in ElementGrouper.toggleCandidates(segments: rest, isToggleShaped: reader.isToggleShaped) {
            // Geometry that already saw which side the knob is on beats any pixel read.
            let read = candidate.inferredState ?? reader.state(
                of: ControlCandidate(box: candidate.rect, shape: .toggle, isAssumed: candidate.isAssumed),
                in: image
            )
            guard let read else { continue }
            readings.append((candidate.rect, read))
        }
        guard !readings.isEmpty else { return scene }
        let size = CGSize(width: image.width, height: image.height)
        var elements = scene.elements
        for reading in readings {
            let owner = elements.indices
                .filter { index in
                    guard elements[index].state == nil else { return false }
                    let box = elements[index].bounds.pixelBox(in: size)
                    let overlap = box.intersection(reading.box)
                    return !overlap.isNull && overlap.area >= 0.5 * min(box.area, reading.box.area)
                }
                .min { elements[$0].bounds.area < elements[$1].bounds.area }
            guard let owner else { continue }
            elements[owner].state = reading.state
        }
        return SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : elements,
            outOfViewFields  : scene.outOfViewFields,
            sections         : scene.sections,
            commands         : scene.commands
        )
    }

    /// Reads each known popup in isolation. Dense surrounding content can make the recognizer
    /// misorient otherwise legible menu labels. Crop results replace only text painted inside that
    /// popup, with their coordinates translated back into the captured image at its backing scale.
    private func recognizeText(in image: CGImage, of window: Window) async throws -> [RecognizedText] {
        var runs = try await text.recognizeTextCancellably(in: image, accuracy: accuracy)
        guard let frame = window.frame, frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return runs }
        let pixels = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        var covered: [CGRect] = []
        for overlay in window.occludingFrames {
            try Task.checkCancellation()
            guard overlay.width > 0, overlay.height > 0,
                  [overlay.minX, overlay.minY, overlay.width, overlay.height].allSatisfy(\.isFinite) else { continue }
            let crop = CGRect(
                x: (overlay.minX - frame.minX) * scaleX,
                y: (overlay.minY - frame.minY) * scaleY,
                width: overlay.width * scaleX,
                height: overlay.height * scaleY
            ).integral.intersection(pixels)
            guard crop.width >= 2, crop.height >= 2,
                  let cropped = image.cropping(to: crop) else { continue }
            let local = try await text.recognizeTextCancellably(in: cropped, accuracy: accuracy)
            func belongs(_ box: CGRect) -> Bool {
                let point = CGPoint(x: box.midX, y: box.midY)
                return crop.contains(point) && !covered.contains { $0.contains(point) }
            }
            runs.removeAll { belongs($0.pixelBox) }
            runs += local.compactMap { run in
                let box = run.pixelBox.offsetBy(dx: crop.minX, dy: crop.minY)
                return belongs(box) ? RecognizedText(text: run.text, pixelBox: box) : nil
            }
            covered.append(crop)
        }
        return runs
    }

    private func augmentationElements(for window: Window) async throws -> AccessibilityHarvest {
        guard let augmentation, let processID = window.processID, let frame = window.frame else { return .none }
        var harvest: AccessibilityHarvest
        if let windowNumber = window.windowNumber {
            harvest = try await augmentation.augmentation(
                for: processID, windowNumber: windowNumber, windowFrame: frame
            )
        } else {
            harvest = try await augmentation.augmentation(for: processID, windowFrame: frame)
        }
        // The window's native tree describes controls behind an overlay, not that overlay's rows.
        harvest.elements.removeAll { element in
            let box = element.bounds.pixelBox(in: frame.size).offsetBy(dx: frame.minX, dy: frame.minY)
            return window.occludingFrames.contains { $0.width > 0 && $0.height > 0 && $0.intersects(box) }
        }
        return harvest
    }

    /// Reads one region before text recognition and grouping, so nearby captions cannot become
    /// part of a control's value. Bounds are normalized to the supplied image; the result is local
    /// to the crop. Invalid or partly outside bounds return nil rather than silently clipping.
    /// Accessibility augmentation is disabled because its coordinates belong to the whole window.
    public func perceive(
        _ image: CGImage,
        inside bounds: NormalizedRect,
        of window: Window
    ) async throws -> SceneSnapshot? {
        let rect = bounds.cgRect
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect) else { return nil }
        let pixels = bounds.pixelBox(in: CGSize(width: image.width, height: image.height)).integral
        guard let crop = image.cropping(to: pixels) else { return nil }
        let local = Window(bundleID: window.bundleID, appName: window.appName, title: window.title)
        return try await perceive(crop, of: local)
    }

    /// Merges a harvest into a pixel-built scene and keeps its quality beside the result. Pure; what
    /// a fixture calls to produce a capture without an image.
    public static func augmented(_ scene: SceneSnapshot, with harvest: AccessibilityHarvest) -> SceneCapture {
        var merged = augmented(scene, with: harvest.elements)
        merged.outOfViewFields = harvest.outOfViewFields
        merged.token = SceneToken(
            bundleID: merged.bundleID, windowTitle: merged.windowTitle,
            elements: merged.elements, outOfViewFields: merged.outOfViewFields
        )
        return SceneCapture(scene: merged, quality: harvest.quality)
    }

    /// Merges harvested elements into a pixel-built scene and recomputes the token. Pure; what
    /// `capture` calls after the augmenter has answered.
    public static func augmented(_ scene: SceneSnapshot, with harvested: [SceneElement]) -> SceneSnapshot {
        guard !harvested.isEmpty else { return scene }
        var merged = AccessibilityAugmentation.merge(pixels: scene.elements, accessibility: harvested)
        if !scene.sections.isEmpty {
            // A harvested element takes the panel it lands in, like every other element.
            let rects = scene.sections.map(\.bounds)
            let names = scene.sections.map(\.name)
            for index in merged.indices where merged[index].section == nil {
                let center = merged[index].bounds.center
                var best: Int?
                for (rectIndex, rect) in rects.enumerated() where rect.contains(center) {
                    if let current = best, rects[current].area <= rect.area { continue }
                    best = rectIndex
                }
                if let best { merged[index].section = names[best] }
            }
        }
        return SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : merged,
            outOfViewFields  : scene.outOfViewFields,
            sections         : scene.sections,
            commands         : scene.commands
        )
    }

    /// Assembles a scene from already-recognized runs and segments. Pure; what `perceive` calls after
    /// the roles have answered, and what a test can call without an image.
    public static func assemble(
        runs     : [RecognizedText],
        segments : [CGRect],
        imageSize: CGSize,
        window   : Window,
        images   : [CGRect] = [],
        overlays : [CGRect] = []
    ) -> SceneSnapshot {
        let usable = runs.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let textRuns = usable.map { ElementGrouper.TextRun(rect: $0.pixelBox, text: $0.text) }
        let ocrBoxes = usable.map(\.pixelBox)
        let lineHeight: CGFloat = {
            let heights = ocrBoxes.map(\.height).sorted()
            return heights.count >= 3 ? heights[heights.count / 2] : 0
        }()
        // An icon is at most a modest fraction of the window, unless a centered caption beneath it
        // says it is a thumbnail, which may be up to half the frame.
        let minSide = min(imageSize.width, imageSize.height)
        let iconMaxSide = 0.14 * minSide, thumbnailMaxSide = 0.5 * minSide
        var icons: [ElementGrouper.IconCandidate] = []
        for segment in segments {
            let box = segment.integral
            let side = max(box.width, box.height)
            guard box.width >= 10, box.height >= 10, box.width <= 4 * box.height,
                  box.height <= 4 * box.width,
                  side <= iconMaxSide
                      || (side <= thumbnailMaxSide && ElementGrouper.hasCaptionBelow(box, ocrBoxes: ocrBoxes)),
                  !ElementGrouper.isTextGlyph(box, ocrBoxes: ocrBoxes, lineHeight: lineHeight),
                  !ocrBoxes.contains(where: { $0.intersection(box).area >= 0.6 * box.area })
            else { continue }
            icons.append(ElementGrouper.IconCandidate(rect: box))
        }
        let grouped: [ElementGrouper.GroupedElement]
        if window.sectionRects.isEmpty {
            grouped = ElementGrouper.group(texts: textRuns, icons: icons)
        } else {
            let panels = window.sectionRects.map { $0.pixelBox(in: imageSize) }
            func panel(_ rect: CGRect) -> Int {
                panels.indices.filter { panels[$0].contains(CGPoint(x: rect.midX, y: rect.midY)) }
                    .min { panels[$0].area < panels[$1].area } ?? -1
            }
            let textsByPanel = Dictionary(grouping: textRuns) { panel($0.rect) }
            let iconsByPanel = Dictionary(grouping: icons) { panel($0.rect) }
            grouped = ([-1] + Array(panels.indices)).flatMap {
                ElementGrouper.group(texts: textsByPanel[$0] ?? [], icons: iconsByPanel[$0] ?? [])
            }
        }
        var elements = grouped.map { element -> SceneElement in
            let bounds = NormalizedRect(pixelBox: element.rect, in: imageSize)
            let label = element.isUnlabeled ? "(unlabeled)" : element.label
            return SceneElement(
                id         : SceneIdentity.key(
                    kind: element.kind, label: element.label, bounds: bounds, isUnlabeled: element.isUnlabeled
                ),
                kind       : element.kind,
                label      : label,
                bounds     : bounds,
                state      : element.state,
                isUnlabeled: element.isUnlabeled
            )
        }
        for (kind, boxes) in [(ElementKind.image, images), (.overlayCandidate, overlays)] {
            for box in boxes {
                let bounds = NormalizedRect(pixelBox: box, in: imageSize)
                let label = kind == .image ? "image" : "(unlabeled)"
                let unlabeled = kind == .overlayCandidate
                elements.append(SceneElement(
                    id: SceneIdentity.key(kind: kind, label: label, bounds: bounds, isUnlabeled: unlabeled),
                    kind: kind,
                    label: label,
                    bounds: bounds,
                    isUnlabeled: unlabeled
                ))
            }
        }
        var sections: [SceneSection] = []
        if !window.sectionRects.isEmpty {
            (elements, sections) = SceneComposer.compose(elements: elements, sectionRects: window.sectionRects)
        }
        return SceneSnapshot(
            bundleID         : window.bundleID,
            appName          : window.appName,
            windowTitle      : window.title,
            viewportPixelSize: ViewportPixelSize(width: Int(imageSize.width), height: Int(imageSize.height)),
            elements         : elements,
            sections         : sections,
            commands         : window.commands
        )
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
