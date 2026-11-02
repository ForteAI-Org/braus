//
//  CanvasDetectionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import MacDriver
import Perception
import PerceptionCore
import Testing

/// Canvases in the scene of the recorded canvas fixture: which areas are canvases, their ids and frames.
@Suite("Canvas detection on the recorded fixture")
struct CanvasDetectionTests {

    /// Replays a recording's harvest as the live augmenter would answer it.
    struct RecordedAugmenter: SceneAugmenting {
        let harvest: AccessibilityHarvest

        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            harvest
        }
    }

    /// Reads no text, so the scene holds only what accessibility and the canvas rule put there.
    struct NoText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] { [] }
    }

    static func scene(_ variant: String) async throws -> (scene: SceneSnapshot, image: CGImage) {
        let recording = try CanvasFixtures.load(variant)
        let frame = try #require(recording.tree.frame)
        let harvest = AccessibilityAugmentation.harvest(
            under      : recording.tree,
            windowFrame: frame,
            reader     : CanvasFixtures.Reader()
        )
        let pipeline = ScenePipeline(
            text        : NoText(),
            augmentation: RecordedAugmenter(harvest: harvest)
        )
        let window = ScenePipeline.Window(
            bundleID : "com.braus.fixture.canvas",
            appName  : "Canvas Fixture",
            title    : "Canvas Fixture",
            processID: 1,
            frame    : frame
        )
        return (try await pipeline.capture(recording.image, of: window).scene, recording.image)
    }

    static func canvases(_ scene: SceneSnapshot) -> [SceneElement] {
        scene.elements.filter { $0.kind == .canvas }
    }

    /// The window-normalized rectangle of a frame in the recording's global points.
    private static func normalized(_ frame: CGRect) -> NormalizedRect {
        NormalizedRect(
            x     : Double((frame.minX - 214) / 1100),
            y     : Double((frame.minY - 33) / 732),
            width : Double(frame.width / 1100),
            height: Double(frame.height / 732)
        )
    }

    @Test("The timeline and the image are canvases; the empty view and the controls are not")
    func detectsCanvases() async throws {
        let recording = try CanvasFixtures.load("still")
        let frame = try #require(recording.tree.frame)
        let harvest = AccessibilityAugmentation.harvest(
            under      : recording.tree,
            windowFrame: frame,
            reader     : CanvasFixtures.Reader()
        )
        // Accessibility alone proposes all three drawn views, in tree order.
        #expect(harvest.elements.filter { $0.kind == .canvas }.map(\.label) == ["canvas 1", "canvas 2", "canvas 3"])
        #expect(harvest.quality.walkCompleted == true)

        let scene = try await Self.scene("still").scene
        let canvases = Self.canvases(scene)
        #expect(canvases.map(\.label) == ["canvas 1", "canvas 2"])
        #expect(canvases.map(\.id) == ["canvas|canvas1", "canvas|canvas2"])
        #expect(canvases.map(\.role) == ["AXGroup", "AXImage"])
        let expected = [
            Self.normalized(CGRect(x: 374, y: 205, width: 900, height: 320)),
            Self.normalized(CGRect(x: 374, y: 565, width: 620, height: 160)),
        ]
        for (canvas, bounds) in zip(canvases, expected) {
            #expect(zip(canvas.bounds.array, bounds.array).allSatisfy { abs($0 - $1) < 1e-9 }, "\(canvas.label)")
        }
        // The empty view's place holds no canvas, and every control keeps its own kind.
        let empty = Self.normalized(CGRect(x: 1034, y: 565, width: 240, height: 160))
        #expect(!canvases.contains { $0.bounds.cgRect.intersects(empty.cgRect) })
        for label in ["Play", "Search", "Zoom", "Track 1", "00:00"] {
            let element = try #require(scene.elements.first { $0.label == label }, "\(label)")
            #expect(element.kind != .canvas)
        }
        #expect(scene.text().contains("[canvas] canvas 1 @15,23 82x44\n"))
    }

    @Test("A canvas keeps its id across recordings of the same window")
    func stableIdentifiers() async throws {
        let still = Self.canvases(try await Self.scene("still").scene).map(\.id)
        let moved = Self.canvases(try await Self.scene("clip-moved").scene).map(\.id)
        #expect(still == ["canvas|canvas1", "canvas|canvas2"])
        #expect(moved == still)
    }

    @Test("A window without canvases renders exactly as before canvases existed")
    func sceneWithoutCanvasesUnchanged() throws {
        let recording = try CanvasFixtures.load("still")
        let frame = try #require(recording.tree.frame)
        var tree = recording.tree
        tree.children.removeAll { ($0.identifier ?? "").hasPrefix("canvas.") }
        let elements = AccessibilityAugmentation.harvest(
            under      : tree,
            windowFrame: frame,
            reader     : CanvasFixtures.Reader()
        ).elements
        let scene = SceneSnapshot(
            bundleID         : "com.braus.fixture.canvas",
            appName          : "Canvas Fixture",
            windowTitle      : "Canvas Fixture",
            viewportPixelSize: ViewportPixelSize(width: 1100, height: 732),
            elements         : elements
        )
        #expect(scene.text() == Self.canvasFreeText)
    }

    /// `text()` of the fixture without its drawn views, as printed before the canvas kind existed.
    private static let canvasFreeText = """
        Canvas Fixture (com.braus.fixture.canvas) "Canvas Fixture" 1100x732, 16 elements
        Canvas Fixture @7,1
        [control] Play @2,8
        [field] Search id:'control|search' = "" @13,8
        [control] Search #2 @13,9
        [control] Zoom = 100% @40,8
        00:00 @15,19
        00:05 @27,19
        00:10 @39,19
        00:15 @51,19
        00:20 @64,19
        00:25 @76,19
        00:30 @88,19
        Track 1 @3,27
        Track 2 @3,38
        Track 3 @3,49
        Track 4 @3,60

        """
}
