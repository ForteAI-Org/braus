//
//  CanvasCropTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import ImageIO
@testable import IncrementalText
import PerceptionCore
import Testing

/// Crops of the recorded canvas fixture: their rectangle, size, privacy, caption and what the
/// history keeps for them. The recordings are 1x, so a window point is one pixel.
@Suite("Canvas crops of the recorded fixture")
struct CanvasCropTests {

    static let timeline = "canvas|canvas1"
    static let picture  = "canvas|canvas2"
    static let window   = CGSize(width: 1100, height: 732)
    /// Lane 2's clip before and after the move, in window points: 185 wide from x 255 to 375.
    static let laneTwoChange = CGRect(
        x     : 255,
        y     : 272,
        width : 305,
        height: 44
    )

    /// The history after observing `first` and then `second`, with a Command at `points` between them.
    static func history(
        _ first : (scene: SceneSnapshot, image: CGImage),
        _ second: (scene: SceneSnapshot, image: CGImage),
        points  : [CGPoint] = []
    ) -> (history: CanvasHistory, scene: SceneSnapshot) {
        var history = CanvasHistory()
        var one = first.scene
        var two = second.scene
        history.observe(
            &one,
            in           : first.image,
            window       : 1,
            windowSize   : window,
            displayedAt  : 10,
            lastCommandAt: nil
        )
        history.noteAction(at: points)
        history.observe(
            &two,
            in           : second.image,
            window       : 1,
            windowSize   : window,
            displayedAt  : 30,
            lastCommandAt: 20
        )
        return (history, two)
    }

    static func crop(_ answer: CanvasHistory.Answer) throws -> (crop: CanvasCrop, caption: String) {
        guard case .crop(let crop, let caption) = answer else {
            Issue.record("expected a crop, got \(answer)")
            throw CancellationError()
        }
        return (crop, caption)
    }

    static func image(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The RGBA bytes of one pixel of `image`, top-left origin.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data            : buffer.baseAddress,
                width           : 1,
                height          : 1,
                bitsPerComponent: 8,
                bytesPerRow     : 4,
                space           : CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(
                image,
                in: CGRect(
                    x     : -x,
                    y     : y - image.height + 1,
                    width : image.width,
                    height: image.height
                )
            )
        }
        return bytes
    }

    /// Writes the crops of the fixture case when BRAUS_CANVAS_CROP_DIR names a folder, for a person
    /// to look at.
    static func write(_ crop: CanvasCrop, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BRAUS_CANVAS_CROP_DIR"] else { return }
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try crop.before.write(to: directory.appendingPathComponent("\(name)-before.png"))
        try crop.after.write(to: directory.appendingPathComponent("\(name)-after.png"))
    }

    @Test("Moving lane 2's clip crops that area with its margin at 1x, for about a hundred tokens")
    func laneTwoCrop() async throws {
        let (history, _) = Self.history(
            try await CanvasDetectionTests.scene("still"),
            try await CanvasDetectionTests.scene("clip-moved")
        )
        let (crop, caption) = try Self.crop(try history.crop(Self.timeline, isWithheld: { _ in false }))
        let rect = crop.layout.rect
        print("CANVAS_CROP lane 2: \(rect) \(crop.layout.pixelWidth)x\(crop.layout.pixelHeight) px, "
            + "Claude \(crop.claudeTokens), GPT \(crop.gptTokens) tokens per pair, "
            + "PNG \(crop.before.count)+\(crop.after.count) bytes\n\(caption)")
        // The change grown by the margin, rounded out to the 32-point tiles it was found in. Sampling
        // one pixel in four can leave up to three columns of a change to the next tile, as here: the
        // clip's edge at x 255 is seen in the tile from 256, so the margin left of it is 3 points less.
        let grown = Self.laneTwoChange.insetBy(dx: -(CanvasCrop.margin - 3), dy: -CanvasCrop.margin)
        #expect(rect.contains(grown))
        #expect(grown.insetBy(dx: -32, dy: -32).contains(rect))
        #expect(rect == CGRect(x: 232, y: 244, width: 368, height: 112))
        #expect(!crop.layout.isWholeCanvas)
        #expect(crop.layout.pixelsPerPoint == 1)
        #expect(crop.layout.pixelWidth == 368 && crop.layout.pixelHeight == 112)
        #expect(crop.claudeTokens == 2 * 14 * 4)
        #expect(crop.gptTokens == 116)
        let before = try Self.image(crop.before)
        let after  = try Self.image(crop.after)
        #expect(before.width == 368 && after.height == 112)
        // At 1x the crop is the window's own pixels: the moved clip and the lanes around it.
        let recording = try CanvasFixtures.load("clip-moved")
        for (x, y) in [(500, 300), (260, 300), (210, 250)] {
            #expect(Self.pixel(after, x: x - 200, y: y - 244) == Self.pixel(recording.image, x: x, y: y))
        }
        #expect(try history.crop(Self.picture, isWithheld: { _ in false }) == .unchanged)
        try Self.write(crop, named: "lane2-1x")
    }

    @Test("Zoom 2 doubles the pixels of the same rectangle")
    func zoomTwo() async throws {
        let (history, _) = Self.history(
            try await CanvasDetectionTests.scene("still"),
            try await CanvasDetectionTests.scene("clip-moved")
        )
        let one = try Self.crop(try history.crop(Self.timeline, isWithheld: { _ in false })).crop
        let two = try Self.crop(try history.crop(Self.timeline, zoom: 2, isWithheld: { _ in false })).crop
        #expect(two.layout.rect == one.layout.rect)
        #expect(two.layout.pixelWidth == 2 * one.layout.pixelWidth)
        #expect(two.layout.pixelHeight == 2 * one.layout.pixelHeight)
        #expect(try Self.image(two.after).width == 736)
        print("CANVAS_CROP lane 2 zoom 2: Claude \(two.claudeTokens), GPT \(two.gptTokens) tokens per pair")
        try Self.write(two, named: "lane2-2x")
    }

    @Test("A change over most of the canvas crops the whole canvas, its long edge at most 1280 px")
    func wholeCanvas() async throws {
        let recording = try CanvasFixtures.load("still")
        let moved = try CanvasFixtures.load("clip-moved")
        let canvas = CGRect(
            x     : 160,
            y     : 172,
            width : 900,
            height: 320
        )
        let wide = canvas.insetBy(dx: 60, dy: 30)
        let one = try #require(CanvasCrop.layout(canvas: canvas, changed: [wide]))
        #expect(one.isWholeCanvas && one.rect == canvas)
        #expect(one.pixelWidth == 900 && one.pixelHeight == 320)
        let two = try #require(CanvasCrop.layout(canvas: canvas, changed: [wide], zoom: 2))
        #expect(two.isWholeCanvas)
        #expect(two.pixelWidth == 1280 && two.pixelHeight == 455)
        let crop = try CanvasCrop.make(
            before: CanvasCrop.Source(image: recording.image, scale: 1),
            after : CanvasCrop.Source(image: moved.image, scale: 1),
            layout: two
        )
        #expect(try Self.image(crop.after).width == 1280)
        // Under the share the crop stays the changed area.
        let narrow = try #require(CanvasCrop.layout(canvas: canvas, changed: [canvas.insetBy(dx: 300, dy: 100)]))
        #expect(!narrow.isWholeCanvas)
        try Self.write(crop, named: "whole-canvas")
    }

    @Test("Nothing changed means no crop")
    func noChange() async throws {
        let still = try await CanvasDetectionTests.scene("still")
        let (history, _) = Self.history(still, still)
        #expect(try history.crop(Self.timeline, isWithheld: { _ in false }) == .unchanged)
        #expect(CanvasCrop.layout(canvas: CGRect(x: 0, y: 0, width: 100, height: 100), changed: []) == nil)
        // A canvas observed once has no before.
        var once = CanvasHistory()
        var scene = still.scene
        once.observe(&scene, in: still.image, window: 1, windowSize: Self.window, displayedAt: 1, lastCommandAt: nil)
        #expect(try once.crop(Self.timeline, isWithheld: { _ in false }) == .unavailable)
    }

    @Test("A learned meter neither marks the timeline changed nor makes a crop")
    func maskedMeter() async throws {
        let still = try await CanvasDetectionTests.scene("still")
        var phase = try await CanvasDetectionTests.scene("meter-phases/3")
        // Without learning, the meter alone changes the timeline.
        let (plain, plainScene) = Self.history(still, phase)
        #expect(plainScene.elements.first { $0.id == Self.timeline }?.hasChangedPixels == true)
        #expect(try plain.crop(Self.timeline, isWithheld: { _ in false }) != .unchanged)

        var history = CanvasHistory()
        var first = still.scene
        history.observe(&first, in: still.image, window: 1, windowSize: Self.window, displayedAt: 10, lastCommandAt: nil)
        for index in 0..<6 {
            let idle = try CanvasFixtures.load("meter-phases/\(index)")
            history.learnIdle(from: idle.image, window: 1, displayedAt: UInt64(11 + index), lastCommandAt: nil)
        }
        #expect(!history.mask(of: Self.timeline).isEmpty)
        history.observe(&phase.scene, in: phase.image, window: 1, windowSize: Self.window, displayedAt: 30, lastCommandAt: 20)
        #expect(phase.scene.elements.first { $0.id == Self.timeline }?.hasChangedPixels == false)
        #expect(try history.crop(Self.timeline, isWithheld: { _ in false }) == .unchanged)

        // The clip still counts once the meter is learned, and its crop leaves the meter out.
        var moved = try await CanvasDetectionTests.scene("clip-moved")
        history.observe(&moved.scene, in: moved.image, window: 1, windowSize: Self.window, displayedAt: 50, lastCommandAt: 40)
        let crop = try Self.crop(try history.crop(Self.timeline, isWithheld: { _ in false })).crop
        #expect(crop.layout.rect == CGRect(x: 232, y: 244, width: 368, height: 112))
    }

    /// The clip-moved recording with the meter of `meter-phases/3` and the playhead drawn at window x 700: an
    /// action's change with two unrelated ones, as right after a session opens, before any noise is learned.
    static func busyClipMove() async throws -> (scene: SceneSnapshot, image: CGImage) {
        let moved = try await CanvasDetectionTests.scene("clip-moved")
        let meter = try CanvasFixtures.load("meter-phases/3").image
        let image = moved.image
        let context = try #require(CGContext(
            data            : nil,
            width           : image.width,
            height          : image.height,
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let height = CGFloat(image.height)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        // Window points (top-left origin) are pixels here; the context's origin is bottom-left.
        let box = CGRect(x: 976, y: 176, width: 80, height: 56)
        let part = try #require(meter.cropping(to: box))
        context.draw(
            part,
            in: CGRect(x: box.minX, y: height - box.maxY, width: box.width, height: box.height)
        )
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 698, y: height - 492, width: 4, height: 320))
        return (moved.scene, try #require(context.makeImage()))
    }

    @Test("Before noise is learned, a moved clip is cropped apart from the meter and playhead that also moved")
    func actionRegionBeforeNoise() async throws {
        let still = try await CanvasDetectionTests.scene("still")
        let busy  = try await Self.busyClipMove()
        // The drag from the clip's old middle to its new one, then no point at all: the clip's region.
        for points in [[CGPoint(x: 347, y: 294), CGPoint(x: 467, y: 294)], []] {
            let (history, scene) = Self.history(
                still,
                busy,
                points: points
            )
            #expect(scene.elements.first { $0.id == Self.timeline }?.hasChangedPixels == true)
            let crop = try Self.crop(try history.crop(Self.timeline, isWithheld: { _ in false })).crop
            print("CANVAS_CROP busy clip move, \(points.count) points: \(crop.layout.rect) "
                + "whole \(crop.layout.isWholeCanvas), Claude \(crop.claudeTokens) tokens per pair")
            #expect(!crop.layout.isWholeCanvas)
            #expect(crop.layout.rect == CGRect(x: 232, y: 244, width: 368, height: 112))
            #expect(crop.claudeTokens == 2 * 14 * 4)
        }
        // A click beside the meter keeps the meter's region, nearest to it, and nothing of the clip.
        let (meter, _) = Self.history(
            still,
            busy,
            points: [CGPoint(x: 940, y: 200)]
        )
        let rect = try Self.crop(try meter.crop(Self.timeline, isWithheld: { _ in false })).crop.layout.rect
        #expect(rect.contains(CGPoint(x: 1016, y: 204)) && rect.minX > 700)
        // Only the action's region counts toward the whole-canvas share.
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let wide   = CGRect(x: 0, y: 0, width: 900, height: 300)
        let dot    = CGRect(x: 960, y: 360, width: 32, height: 32)
        #expect(CanvasCrop.layout(canvas: canvas, changed: [wide, dot], near: [CGPoint(x: 970, y: 370)])?.isWholeCanvas == false)
        #expect(CanvasCrop.layout(canvas: canvas, changed: [wide, dot], near: [CGPoint(x: 10, y: 10)])?.isWholeCanvas == true)
        // A click off the canvas, a toolbar's Play, chooses no region: the largest is kept.
        #expect(CanvasCrop.layout(canvas: canvas, changed: [wide, dot], near: [CGPoint(x: 1500, y: 370)])?.isWholeCanvas == true)
        #expect(CanvasCrop.layout(canvas: canvas, changed: [dot], near: [CGPoint(x: 1500, y: 370)])?.isWholeCanvas == false)
    }

    @Test("Frames with a Command between them teach no noise")
    func inputTeachesNothing() async throws {
        let still = try await CanvasDetectionTests.scene("still")
        var history = CanvasHistory()
        var scene = still.scene
        history.observe(&scene, in: still.image, window: 1, windowSize: Self.window, displayedAt: 10, lastCommandAt: nil)
        for index in 0..<6 {
            let frame = try CanvasFixtures.load("meter-phases/\(index)")
            let time = UInt64(20 + 10 * index)
            history.learnIdle(from: frame.image, window: 1, displayedAt: time, lastCommandAt: time - 5)
        }
        #expect(history.mask(of: Self.timeline).isEmpty)
        // Another window's frame, or one of unknown time, teaches nothing either.
        for index in 0..<6 {
            let frame = try CanvasFixtures.load("meter-phases/\(index)")
            history.learnIdle(from: frame.image, window: 2, displayedAt: UInt64(100 + index), lastCommandAt: nil)
            history.learnIdle(from: frame.image, window: 1, displayedAt: nil, lastCommandAt: nil)
        }
        #expect(history.mask(of: Self.timeline).isEmpty)
        #expect(CanvasHistory.hadInput(from: 10, to: 20, lastCommandAt: 5) == false)
        #expect(CanvasHistory.hadInput(from: 10, to: 20, lastCommandAt: nil) == false)
        #expect(CanvasHistory.hadInput(from: 10, to: 20, lastCommandAt: 15) == true)
        #expect(CanvasHistory.hadInput(from: 20, to: 10, lastCommandAt: nil) == true)
        #expect(CanvasHistory.hadInput(from: nil, to: 10, lastCommandAt: nil) == true)
    }

    @Test("The caption names the tracks beside the timeline and the ruler above it, in crop pixels")
    func caption() async throws {
        let (history, _) = Self.history(
            try await CanvasDetectionTests.scene("still"),
            try await CanvasDetectionTests.scene("clip-moved")
        )
        let caption = try Self.crop(try history.crop(Self.timeline, isWithheld: { _ in false })).caption
        let lines = caption.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines.first?.hasPrefix("canvas 1: crop 368x112 px of window points 232,244 368x112, 1 px per point") == true)
        let rows = try #require(lines.first { $0.hasPrefix("rows (y px): ") })
        for lane in 1...4 { #expect(rows.contains("\"Track \(lane)\" ")) }
        // Track 2's label (window y 278 to 302, within a point of rounding) is inside the crop's height.
        #expect(rows.contains("\"Track 2\" 33..59"))
        let ruler = try #require(lines.first { $0.hasPrefix("above (x px): ") })
        for seconds in stride(from: 0, through: 30, by: 5) {
            #expect(ruler.contains(String(format: "\"00:%02d\" ", seconds)))
        }
        // 00:05 sits near window x 295, about 64 pixels into a crop that starts at 232.
        #expect(ruler.contains("\"00:05\" 64..132"))
    }

    @Test("A field over the crop is blanked; a secure field refuses it")
    func privacy() async throws {
        let still = try await CanvasDetectionTests.scene("still")
        var moved = try await CanvasDetectionTests.scene("clip-moved")
        func element(_ id: String, role: String?, label: String, at frame: CGRect) -> SceneElement {
            SceneElement(
                id    : id,
                kind  : role == nil ? .text : .control,
                label : label,
                bounds: NormalizedRect(pixelBox: frame, in: Self.window),
                role  : role
            )
        }
        let field = CGRect(x: 400, y: 280, width: 100, height: 22)
        let secret = CGRect(x: 230, y: 330, width: 60, height: 20)
        moved.scene.elements += [
            element("field|note", role: "AXTextField", label: "Note", at: field),
            element("text|secret", role: nil, label: "token 1234", at: secret),
        ]
        let (history, _) = Self.history(still, moved)
        let (crop, _) = try Self.crop(try history.crop(Self.timeline, isWithheld: { $0.hasPrefix("token") }))
        #expect(crop.blanked.count == 2)
        let after = try Self.image(crop.after)
        let before = try Self.image(crop.before)
        let grey = Self.pixel(after, x: 450 - 200, y: 290 - 244)
        #expect(grey == [128, 128, 128, 255] || grey == [127, 127, 127, 255])
        #expect(Self.pixel(before, x: 450 - 200, y: 290 - 244) == grey)
        #expect(Self.pixel(after, x: 250 - 200, y: 340 - 244) == grey)
        #expect(Self.pixel(after, x: 300 - 200, y: 300 - 244) != grey)
        try Self.write(crop, named: "lane2-blanked")

        var secure = try await CanvasDetectionTests.scene("clip-moved")
        secure.scene.elements.append(element("field|pin", role: "AXSecureTextField", label: "PIN", at: field))
        #expect(try Self.history(still, secure).history.crop(Self.timeline, isWithheld: { _ in false }) == .refused)
        // A field whose name the report withholds is protected like a secure one.
        var named = try await CanvasDetectionTests.scene("clip-moved")
        named.scene.elements.append(element("field|password", role: "AXTextField", label: "Password", at: field))
        #expect(try Self.history(still, named).history.crop(Self.timeline, isWithheld: { $0 == "Password" }) == .refused)
        // A secure field outside the crop changes nothing.
        var far = try await CanvasDetectionTests.scene("clip-moved")
        far.scene.elements.append(element("field|pin", role: "AXSecureTextField", label: "PIN", at: CGRect(x: 700, y: 400, width: 80, height: 22)))
        #expect(try Self.crop(try Self.history(still, far).history.crop(Self.timeline, isWithheld: { _ in false })).crop.blanked.isEmpty)
    }

    @Test("The history keeps two observations of canvas pixels, at most twice the generation bound")
    func memoryBound() async throws {
        let (fixture, _) = Self.history(
            try await CanvasDetectionTests.scene("still"),
            try await CanvasDetectionTests.scene("clip-moved")
        )
        print("CANVAS_MEMORY fixture (1x, two canvases, two observations): \(fixture.retainedBytes) bytes")
        // The timeline's and the picture's regions in two observations, nothing else of the window.
        #expect(fixture.retainedBytes == 2 * (900 * 320 + 620 * 160) * 4)

        // A canvas covering a whole Retina window of the fixture's size is kept at full resolution.
        let retina = try Self.fullWindowHistory(points: Self.window, scale: 2)
        print("CANVAS_MEMORY 2x full-window canvas 1100x732 pt: \(retina.retainedBytes) bytes")
        #expect(retina.retainedBytes == 2 * 2200 * 1464 * 4)
        #expect(retina.retainedBytes <= 2 * CanvasHistory.maxGenerationBytes)
        // A larger one is reduced to the bound.
        let large = try Self.fullWindowHistory(points: CGSize(width: 2560, height: 1440), scale: 2)
        print("CANVAS_MEMORY 2x full-window canvas 2560x1440 pt: \(large.retainedBytes) bytes")
        #expect(large.retainedBytes <= 2 * CanvasHistory.maxGenerationBytes)
        #expect(large.retainedBytes >= 2 * CanvasHistory.maxGenerationBytes * 95 / 100)
    }

    /// A history after two observations of a window that is one canvas, with a stripe moved between them.
    static func fullWindowHistory(points: CGSize, scale: CGFloat) throws -> CanvasHistory {
        var history = CanvasHistory()
        for (step, x) in [100, 300].enumerated() {
            let context = try #require(CGContext(
                data            : nil,
                width           : Int(points.width * scale),
                height          : Int(points.height * scale),
                bitsPerComponent: 8,
                bytesPerRow     : 0,
                space           : CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.setFillColor(gray: 0.9, alpha: 1)
            context.fill(CGRect(x: x, y: 100, width: 80, height: 80))
            let image = try #require(context.makeImage())
            var scene = SceneSnapshot(
                bundleID         : "com.braus.fixture.canvas",
                appName          : "Canvas",
                windowTitle      : "Canvas",
                viewportPixelSize: ViewportPixelSize(width: image.width, height: image.height),
                elements         : [SceneElement(
                    id    : timeline,
                    kind  : .canvas,
                    label : "canvas 1",
                    bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                )]
            )
            history.observe(
                &scene,
                in           : image,
                window       : 1,
                windowSize   : points,
                displayedAt  : UInt64(10 * (step + 1)),
                lastCommandAt: step == 0 ? nil : 15
            )
            #expect(step == 0 || scene.elements[0].hasChangedPixels == true)
        }
        return history
    }

    @Test("Measures the added canvas cost per observation and per idle frame (informational)")
    func timing() async throws {
        let still = try await CanvasDetectionTests.scene("still")
        let moved = try await CanvasDetectionTests.scene("clip-moved")
        let images = [moved.image, still.image]
        let rounds = 50
        let clock = ContinuousClock()
        var scene = still.scene
        var previous = CanvasTiles.mark(&scene, in: still.image, since: nil)
        let tiles = clock.measure {
            for round in 0..<rounds { previous = CanvasTiles.mark(&scene, in: images[round % 2], since: previous) }
        }
        var history = CanvasHistory()
        let observing = clock.measure {
            for round in 0..<rounds {
                history.observe(
                    &scene,
                    in           : images[round % 2],
                    window       : 1,
                    windowSize   : Self.window,
                    displayedAt  : UInt64(10 * round + 10),
                    lastCommandAt: UInt64(10 * round + 5)
                )
            }
        }
        let idle = clock.measure {
            for round in 0..<rounds {
                history.learnIdle(
                    from         : images[round % 2],
                    window       : 1,
                    displayedAt  : UInt64(10 * rounds + round + 10),
                    lastCommandAt: nil
                )
            }
        }
        let cropping = try clock.measure {
            for _ in 0..<rounds { _ = try Self.history(still, moved).history.crop(Self.timeline, isWithheld: { _ in false }) }
        }
        print("CANVAS_TIMING fixture 1x: tile marks \(tiles / rounds), history observe \(observing / rounds), "
            + "idle frame \(idle / rounds) per call; two observations and a crop \(cropping / rounds)")

        // A Retina window of the fixture's size that is one canvas: a BGRA frame copied as the seat does.
        let bgra = try Self.retinaFrame()
        var retina = CanvasHistory()
        var canvasScene = SceneSnapshot(
            bundleID         : "com.braus.fixture.canvas",
            appName          : "Canvas",
            windowTitle      : "Canvas",
            viewportPixelSize: ViewportPixelSize(width: bgra.width, height: bgra.height),
            elements         : [SceneElement(
                id    : Self.timeline,
                kind  : .canvas,
                label : "canvas 1",
                bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            )]
        )
        let retinaObserving = clock.measure {
            for round in 0..<10 {
                retina.observe(
                    &canvasScene,
                    in           : bgra,
                    window       : 1,
                    windowSize   : Self.window,
                    displayedAt  : UInt64(10 * round + 10),
                    lastCommandAt: UInt64(10 * round + 5)
                )
            }
        }
        var retinaTiles = CanvasTiles.mark(&canvasScene, in: bgra, since: nil)
        let retinaMarks = clock.measure {
            for _ in 0..<10 { retinaTiles = CanvasTiles.mark(&canvasScene, in: bgra, since: retinaTiles) }
        }
        let copying = try clock.measure {
            for _ in 0..<10 { _ = try Self.retinaFrame() }
        }
        let retinaIdle = clock.measure {
            for round in 0..<10 {
                retina.learnIdle(from: bgra, window: 1, displayedAt: UInt64(1000 + round), lastCommandAt: nil)
            }
        }
        print("CANVAS_TIMING 2x full-window canvas 2200x1464 px: tile marks \(retinaMarks / 10), "
            + "history observe \(retinaObserving / 10), "
            + "frame copy \(copying / 10) + idle hashes \(retinaIdle / 10) per idle frame")
    }

    /// A 2200x1464 frame in the seat's 32BGRA layout, copied out of its buffer the way
    /// `SeatFrame.makeCGImage` does.
    static func retinaFrame() throws -> CGImage {
        let width = 2200
        let height = 1464
        var buffer = [UInt8](repeating: 60, count: width * height * 4)
        return try buffer.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data            : bytes.baseAddress,
                width           : width,
                height          : height,
                bitsPerComponent: 8,
                bytesPerRow     : width * 4,
                space           : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ))
            return try #require(context.makeImage())
        }
    }
}
