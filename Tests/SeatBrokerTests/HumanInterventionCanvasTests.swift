//
//  HumanInterventionCanvasTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import CoreGraphics
import Engine
import Foundation
import ImageIO
@testable import InteractionListener
import InteractionObservation
import MacDriver
import Memory
import Perception
import PerceptionCore
import Testing
@testable import SeatBroker

/// Canvases in the report of a person's control, on episodes made of the recorded canvas fixture: the reader answers
/// each read with a recording's scene and pixels, as the window would have shown them.
@Suite("Canvases in the human intervention report", .serialized)
@MainActor
struct HumanInterventionCanvasTests {

    /// The recordings' window: 1100 by 732 points, captured at 1x.
    nonisolated static let surface = InteractionWindow(
        processID: 42,
        number   : 7,
        title    : "Canvas Fixture",
        layer    : 0,
        frame    : CGRect(
            x     : 214,
            y     : 33,
            width : 1100,
            height: 732
        )
    )

    @Test("A drag on lane 2 adds one canvas line and its picture is the crop pair with a caption")
    func dragOnLaneTwo() async throws {
        let episode = try await Self.run(
            initial: "still",
            actions: [(Self.drag(), "clip-moved")]
        )
        let canvases = episode.review.findings.flatMap { $0.canvases ?? [] }
        #expect(canvases.map(\.id) == ["canvas|canvas1"])
        let lines = episode.text.split(separator: "\n").filter { $0.hasPrefix("Canvas changed: ") }
        #expect(lines == ["Canvas changed: canvas 1 (human_step picture 1)."])
        #expect(episode.text.contains("(1 action, 0 without an observed change)"))
        let picture = episode.details.result(.picture(1))
        #expect(!picture.isError)
        #expect(picture.images.map(\.mimeType) == ["image/png", "image/png"])
        let sizes = try picture.images.map { try Self.size(of: $0.data) }
        #expect(sizes == [CGSize(width: 368, height: 112), CGSize(width: 368, height: 112)])
        #expect(picture.text.contains("canvas 1: crop 368x112 px of window points 232,244 368x112"))
        #expect(picture.text.contains("\"Track 2\""))
        #expect(!picture.text.contains("privacy unverified"))
        print("CANVAS_REPORT drag\n\(episode.text)\nCANVAS_PICTURE\n\(picture.text)")
    }

    @Test("A click on Play changes no canvas: the report is the one a reader without pixels gives")
    func clickOnPlay() async throws {
        let pictured = try await Self.run(
            initial: "still",
            actions: [(Self.click("Play"), "still")]
        )
        let plain = try await Self.run(
            initial  : "still",
            actions  : [(Self.click("Play"), "still")],
            hasPixels: false
        )
        #expect(pictured.review.findings.allSatisfy { $0.canvases == nil })
        #expect(!pictured.text.contains("Canvas changed"))
        #expect(pictured.text == plain.text)
        #expect(pictured.details.result(.picture(1)).images.isEmpty)
    }

    @Test("A meter that moves while the person is still is learned as noise and reported as nothing")
    func meterNoise() async throws {
        // The meter bounces between two levels while nobody acts, then the click's read finds it at the other one.
        let learned = try await Self.run(
            initial: "meter-phases/3",
            idle   : ["meter-phases/4", "meter-phases/3", "meter-phases/4"],
            actions: [(Self.click("Play"), "meter-phases/4")]
        )
        #expect(learned.review.findings.allSatisfy { $0.canvases == nil })
        #expect(!learned.text.contains("Canvas changed"))
        // Without the idle frames, the same meter reads as a change of the timeline.
        let unlearned = try await Self.run(
            initial: "meter-phases/3",
            actions: [(Self.click("Play"), "meter-phases/4")]
        )
        #expect(unlearned.text.contains("Canvas changed: canvas 1"))
    }

    // MARK: Episodes

    struct Episode {
        let review : HumanInterventionConsumer.Intervention.Review
        let text   : String
        let details: HumanInterventionDetails
    }

    /// Plays `actions` after the read when control passes (`initial`) and the frames taken while the person is still
    /// (`idle`), each action answered by the read of its recording, then builds the report and its details.
    static func run(
        initial  : String,
        idle     : [String] = [],
        actions  : [(payload: HumanRecordedInteraction, read: String)],
        hasPixels: Bool = true
    ) async throws -> Episode {
        var recordings: [String: (scene: SceneSnapshot, image: CGImage)] = [:]
        for variant in Set([initial] + idle + actions.map(\.read)) {
            recordings[variant] = try await scene(variant)
        }
        let reader = FixtureReader(
            recordings: recordings,
            initial   : initial,
            idle      : idle,
            reads     : actions.map(\.read),
            hasPixels : hasPixels
        )
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents       : 20,
            maximumRetainedBytes: 10_000_000
        )
        let consumer = HumanInterventionConsumer(
            intervention: intervention,
            window      : LentWindow(
                windowNumber: surface.number,
                processID   : surface.processID,
                frame       : surface.frame
            ),
            reader      : reader,
            buttons     : InteractionButtonState()
        )
        await consumer.beginInitialRead()
        // The idle frames are taken one after the other; the request after the last answers nothing.
        try await until { await reader.frameRequests > idle.count || !hasPixels }
        for (index, action) in actions.enumerated() {
            consumer.noteInput(endedAt: ProcessInfo.processInfo.systemUptime)
            let sequence = try await intervention.record(
                action.payload,
                retainedBytes: action.payload.retainedBytes
            )
            await consumer.enqueue(
                sequence,
                payload: action.payload
            )
            try await until { await intervention.status().analyzedCount > index }
        }
        let review = try await consumer.finish()
        let digest = HumanInterventionSummary.digest(review)
        let details = HumanInterventionDetails(
            review      : review,
            digest      : digest,
            intervention: intervention,
            withholding : { $0 }
        )
        return Episode(
            review : review,
            text   : digest.text,
            details: details
        )
    }

    private static func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func click(_ title: String) -> HumanRecordedInteraction {
        let element = InteractionElementMetadata.read(isReservedLabel: ValueMinimization.namesSecret) {
            ["AXRole": "AXButton", "AXTitle": title][$0] ?? nil
        }
        return HumanRecordedInteraction(
            event     : event(.click, at: CGPoint(x: 283, y: 683)),
            element   : element,
            endElement: nil,
            commandName: nil,
            picture   : nil
        )
    }

    /// Lane 2's clip dragged 120 points right, from inside the timeline: no element is under the pointer.
    static func drag() -> HumanRecordedInteraction {
        HumanRecordedInteraction(
            event     : event(
                .drag,
                at: CGPoint(x: 214 + 300, y: 33 + 294),
                to: CGPoint(x: 214 + 420, y: 33 + 294)
            ),
            element   : nil,
            endElement: nil,
            commandName: nil,
            picture   : nil
        )
    }

    private static func event(
        _ kind  : InteractionEvent.Kind,
        at point: CGPoint,
        to end  : CGPoint? = nil
    ) -> InteractionEvent {
        let now = ProcessInfo.processInfo.systemUptime
        return InteractionEvent(
            kind             : kind,
            timestamp        : Date(),
            startedAt        : now - 0.1,
            endedAt          : now,
            precedingRevision: 0,
            revision         : 1,
            point            : point,
            window           : surface,
            processID        : surface.processID,
            sequence         : 1,
            endPoint         : end,
            clickCount       : kind == .click ? 1 : nil
        )
    }

    static func size(of png: Data) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: Recordings

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Perception/Fixtures/Canvas")

    /// A recording's scene as an accessibility-only read perceives it, with its window picture.
    static func scene(_ variant: String) async throws -> (scene: SceneSnapshot, image: CGImage) {
        let url = directory.appendingPathComponent(variant)
        let tree = try JSONDecoder().decode(
            MacTreeNode.self,
            from: Data(contentsOf: url.appendingPathExtension("json"))
        ).addressed()
        let source = try #require(CGImageSourceCreateWithURL(url.appendingPathExtension("png") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let frame = try #require(tree.frame)
        let pipeline = ScenePipeline(
            text        : NoText(),
            augmentation: RecordedAugmenter(harvest: AccessibilityAugmentation.harvest(
                under      : tree,
                windowFrame: frame,
                reader     : TreeReader()
            ))
        )
        let window = ScenePipeline.Window(
            bundleID : "com.braus.fixture.canvas",
            appName  : "Canvas Fixture",
            title    : "Canvas Fixture",
            processID: surface.processID,
            frame    : frame
        )
        return (try await pipeline.perceive(image, of: window), image)
    }

    private struct RecordedAugmenter: SceneAugmenting {
        let harvest: AccessibilityHarvest

        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest { harvest }
    }

    private struct NoText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] { [] }
    }

    private struct TreeReader: AccessibilityTreeReading {
        func role(_ node: MacTreeNode) -> String? { node.role }
        func subrole(_ node: MacTreeNode) -> String? { node.subrole }
        func title(_ node: MacTreeNode) -> String? { node.title }
        func descriptionText(_ node: MacTreeNode) -> String? { node.descriptionText }
        func identifier(_ node: MacTreeNode) -> String? { node.identifier }
        func value(_ node: MacTreeNode) -> String? { node.value }
        func numericValue(_ node: MacTreeNode) -> Int? { node.value.flatMap(Int.init) }
        func isEnabled(_ node: MacTreeNode) -> Bool? { node.isEnabled }
        func actions(_ node: MacTreeNode) -> [String] { node.actions }
        func frame(_ node: MacTreeNode) -> CGRect? { node.frame }
        func children(_ node: MacTreeNode) -> [MacTreeNode] { node.children }
        func readChildren(_ node: MacTreeNode) -> [MacTreeNode]? {
            node.unread?.children == true ? nil : node.children
        }
    }

    /// FixtureReader answers the read when control passes with `initial`, the frames taken while the person is still
    /// with `idle` in order, then nothing, and each action's read with the next of `reads`; every later read, the
    /// final one included, with the last. Without pixels it is a reader that captures none.
    private actor FixtureReader: HumanSceneReading {
        let recordings: [String: (scene: SceneSnapshot, image: CGImage)]
        let initial   : String
        let idle      : [String]
        let reads     : [String]
        let hasPixels : Bool
        private(set) var frameRequests = 0
        private var readCount = 0

        init(
            recordings: [String: (scene: SceneSnapshot, image: CGImage)],
            initial   : String,
            idle      : [String],
            reads     : [String],
            hasPixels : Bool
        ) {
            self.recordings = recordings
            self.initial    = initial
            self.idle       = idle
            self.reads      = reads
            self.hasPixels  = hasPixels
        }

        private func recording(_ variant: String) -> (scene: SceneSnapshot, frame: HumanInterventionCanvases.Frame) {
            let recording = recordings[variant]!
            return (recording.scene, .init(image: recording.image, capturedAt: DispatchTime.now().uptimeNanoseconds))
        }

        private func nextRead() -> (scene: SceneSnapshot, frame: HumanInterventionCanvases.Frame?) {
            let read = recording(reads[min(readCount, reads.count - 1)])
            readCount += 1
            return (read.scene, hasPixels ? read.frame : nil)
        }

        func read(
            window: InteractionWindow,
            mode  : ProductionPerception.Mode,
            timing: NativeHumanSceneReader.Timing
        ) async throws -> (scene: SceneSnapshot, frame: HumanInterventionCanvases.Frame?) {
            nextRead()
        }

        func scene(
            window: InteractionWindow,
            mode  : ProductionPerception.Mode,
            timing: NativeHumanSceneReader.Timing
        ) async throws -> SceneSnapshot {
            nextRead().scene
        }

        func canvasRead(window: InteractionWindow) async throws -> (scene: SceneSnapshot, frame: HumanInterventionCanvases.Frame)? {
            hasPixels ? recording(initial) : nil
        }

        func frame(of window: InteractionWindow) async throws -> HumanInterventionCanvases.Frame? {
            defer { frameRequests += 1 }
            return frameRequests < idle.count ? recording(idle[frameRequests]).frame : nil
        }

        func windows(processID: Int32) async throws -> [InteractionWindow] { [HumanInterventionCanvasTests.surface] }
    }
}
