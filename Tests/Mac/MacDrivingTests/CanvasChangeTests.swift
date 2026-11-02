//
//  CanvasChangeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import IncrementalText
import MacDriver
@testable import Perception
import PerceptionCore
import Testing

/// Whether a canvas of the recorded fixture changed between two observations of its window.
@Suite("Canvas changes between recordings")
struct CanvasChangeTests {

    @Test("Only the timeline changed when a clip moved; a first observation carries no flag")
    func changedCanvases() async throws {
        var (still, stillImage) = try await CanvasDetectionTests.scene("still")
        var (moved, movedImage) = try await CanvasDetectionTests.scene("clip-moved")
        let first = CanvasTiles.mark(&still, in: stillImage, since: nil)
        #expect(CanvasDetectionTests.canvases(still).allSatisfy { $0.hasChangedPixels == nil })
        _ = CanvasTiles.mark(&moved, in: movedImage, since: first)
        #expect(CanvasDetectionTests.canvases(moved).map(\.hasChangedPixels) == [true, false])
        #expect(moved.text().contains("[canvas] canvas 1 [changed] @15,23 82x44\n"))
        #expect(moved.text().contains("[canvas] canvas 2 [unchanged] @15,73 56x22\n"))

        let diff = SceneChanges.text(from: still, to: moved, since: 1)
        #expect(diff == "~ [canvas] canvas 1 [changed] @15,23 82x44  (was other pixels)")

        var again = moved
        let second = CanvasTiles.mark(&again, in: movedImage, since: nil)
        _ = CanvasTiles.mark(&again, in: movedImage, since: second)
        #expect(CanvasDetectionTests.canvases(again).map(\.hasChangedPixels) == [false, false])
    }

    @Test("A canvas whose region changed size is changed")
    func resizedCanvas() async throws {
        var (still, image) = try await CanvasDetectionTests.scene("still")
        let first = CanvasTiles.mark(&still, in: image, since: nil)
        var resized = still
        let index = try #require(resized.elements.firstIndex { $0.label == "canvas 2" })
        resized.elements[index].bounds.width *= 0.5
        _ = CanvasTiles.mark(&resized, in: image, since: first)
        #expect(CanvasDetectionTests.canvases(resized).map(\.hasChangedPixels) == [false, true])
    }

    @Test("Measures the canvas cost per observation (Debug, informational)")
    func timing() async throws {
        let recording = try CanvasFixtures.load("still")
        let moved = try CanvasFixtures.load("clip-moved")
        var (scene, _) = try await CanvasDetectionTests.scene("still")
        let frame = try #require(recording.tree.frame)
        let harvest = AccessibilityAugmentation.harvest(
            under      : recording.tree,
            windowFrame: frame,
            reader     : CanvasFixtures.Reader()
        )
        let rounds = 50
        let clock = ContinuousClock()
        var previous = CanvasTiles.mark(&scene, in: recording.image, since: nil)
        let images = [moved.image, recording.image]
        let flat = clock.measure {
            for round in 0..<rounds { _ = ScenePipeline.withoutEmptyCanvases(harvest, in: images[round % 2]) }
        }
        let tiles = clock.measure {
            for round in 0..<rounds { previous = CanvasTiles.mark(&scene, in: images[round % 2], since: previous) }
        }
        print("CANVAS_TIMING flat check: \(flat / rounds), tile marks: \(tiles / rounds) per observation")
    }
}
