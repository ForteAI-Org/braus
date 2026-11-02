//
//  HumanInterventionConsumerTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import ImageIO
import Memory
import Perception
import PixelRegions
import PixelSections
import CoreGraphics
import Engine
import Foundation
@testable import InteractionListener
import InteractionObservation
import PerceptionCore
import Synchronization
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionConsumerTests {
    private let window = LentWindow(windowNumber: 7, processID: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    @Test func releasingTheTransferredReviewPreventsReconstructionFromRestarting() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        await consumer.releaseReview()
        try await append(1, to: consumer, intervention: intervention)
        let review = try await consumer.finish()
        let repeated = try await consumer.finish()
        #expect(repeated.revision == review.revision)
        try await intervention.resolve(review.revision, as: .resume)
        let retainedBytes = await intervention.status().retainedBytes
        let completedReads = await reader.windows
        await consumer.releaseReview()
        await consumer.releaseReview()
        await consumer.enqueue(2, payload: payload(2))
        await #expect(throws: HumanInterventionConsumer.Intervention.Failure.invalidPhase) {
            try await consumer.finish()
        }
        #expect(await reader.windows == completedReads)
        #expect(review.payloads.count == 1)
        #expect(await intervention.status().phase == .resumed)
        #expect(await intervention.status().retainedBytes == retainedBytes)
        await intervention.finishResumedTurn()
        #expect(await intervention.status().retainedBytes == 0)
    }

    private func payload(_ sequence: UInt64, window number: Int = 7) -> HumanRecordedInteraction {
        HumanRecordedInteraction(
            event: .init(kind: .click, timestamp: Date(), startedAt: 1, endedAt: 2,
                         precedingRevision: 0, revision: sequence, point: .zero,
                         window: .init(processID: 42, number: number, title: "Mix", layer: 0, frame: window.frame),
                         processID: 42, sequence: sequence),
            element: nil, endElement: nil, commandName: nil, picture: nil)
    }

    private func append(_ sequence: UInt64, window: Int = 7, to consumer: HumanInterventionConsumer,
                        intervention: HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>) async throws {
        let payload = payload(sequence, window: window)
        let number = try await intervention.record(payload, retainedBytes: 0)
        await consumer.enqueue(number, payload: payload)
    }

    @Test func plainClickReleaseStartsReadingWithoutFurtherInput() async throws {
        let buttons = InteractionButtonState()
        let stream = AsyncThrowingStream<InteractionEvent, any Error>.makeStream()
        let tap = TapContext(buttons: buttons, continuation: stream.continuation, hover: false, excludedPID: -1)
        tap.snapshot.withLock {
            $0 = AttributionSnapshot(generation: 1, windows: [
                .init(processID: 42, number: 7, title: "Mix", layer: 0, frame: window.frame)
            ])
        }
        let event = try #require(CGEvent(source: nil))
        event.location = CGPoint(x: 20, y: 20)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 99)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 42)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 7)
        tap.receive(type: .leftMouseDown, event: event)
        let revision = tap.revision
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader, buttons: buttons)
        try await append(1, to: consumer, intervention: intervention)
        tap.receive(type: .leftMouseUp, event: event)
        #expect(buttons.snapshot().processID == nil)
        #expect(tap.revision == revision)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await intervention.status().analyzedCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await reader.windows == [7])
        #expect(await intervention.status().analyzedCount == 1)
        await consumer.cancel()
    }

    @Test(arguments: ["keyboard", "own window", "missing window", "menu bar", "closed menu"])
    func selectsAppSurfacesAndRetainsAllFinalPanels(scenario: String) async throws {
        func surface(_ number: Int, _ layer: Int = 0, _ width: Double = 400, _ height: Double = 300,
                     pid: Int32 = 42) -> InteractionWindow {
            .init(processID: pid, number: number, title: "Window", layer: layer,
                  frame: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let decoration = surface(34304, 0, 66, 20)
        let document = surface(7, 0, 800, 600)
        let menu = surface(90, 101)
        let listed = [surface(99, pid: 99), decoration, surface(21, 8), surface(19), document, surface(20)]
        let own: InteractionWindow? = switch scenario {
        case "own window": document
        case "missing window": surface(100)
        case "menu bar": surface(80, 24, 1000, 24)
        case "closed menu": menu
        default: decoration
        }
        let interaction = HumanRecordedInteraction(
            event: .init(kind: scenario == "menu bar" || scenario == "closed menu" ? .click : .shortcut,
                         timestamp: Date(), startedAt: 1, endedAt: 2, precedingRevision: 0, revision: 1,
                         point: .zero, window: own, processID: 42, sequence: 1),
            element: scenario == "menu bar" ? .read(isReservedLabel: { _ in false }, attribute: { $0 == "AXRole" ? "AXMenuBarItem" : nil }) : nil,
            endElement: nil, commandName: nil, picture: nil)
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(listedWindows: listed)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        let sequence = try await intervention.record(interaction, retainedBytes: 0)
        await consumer.enqueue(sequence, payload: interaction)
        let review = try await consumer.finish()
        let chosen = scenario == "own window" ? 7 : 21
        #expect(review.findings.first?.windowNumber == chosen)
        #expect(await reader.windows == [chosen, 21, 19, 7])
        #expect(review.finalState.kind == .keyframe)
        let text = try review.finalState.text()
        #expect(text.contains("window #7") && text.contains("window #19") && text.contains("window #21"))
        #expect(!text.contains("34304") && !text.contains("window #20") && !text.contains("window #99"))
        if scenario == "closed menu" {
            #expect(try review.findings.first?.text().contains("read of window #21 (menu closed)") == true)
        }
    }

    @Test(arguments: [false, true])
    func transientReadFailureFallsBackOnlyAfterTheMenuVanishes(vanishes: Bool) async throws {
        let menu = InteractionWindow(processID: 42, number: 90, title: "Menu", layer: 101,
                                     frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let document = InteractionWindow(processID: 42, number: 7, title: "Edit", layer: 0, frame: window.frame)
        let interaction = HumanRecordedInteraction(
            event: .init(kind: .click, timestamp: Date(), startedAt: 1, endedAt: 2,
                         precedingRevision: 0, revision: 1, point: .zero, window: menu, processID: 42, sequence: 1),
            element: nil, endElement: nil, commandName: nil, picture: nil)
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(failingWindows: [90], listedWindows: [menu, document],
                            vanishingWindows: vanishes ? [90] : [])
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        let sequence = try await intervention.record(interaction, retainedBytes: 0)
        await consumer.enqueue(sequence, payload: interaction)
        let review = try await consumer.finish()
        #expect(await reader.windows == (vanishes ? [90, 7, 7] : [90, 7]))
        #expect(await reader.modes == (vanishes ? [.textOnly, .textOnly, .full] : [.textOnly, .full]))
        #expect(review.findings.first?.kind == (vanishes ? .keyframe : .failed))
        #expect(try review.findings.first?.text().contains("read of window #7 (menu closed)") == vanishes)
        let attempts = review.findings.first?.provenance?.surfaces ?? []
        #expect(attempts.first?.windowNumber == 90 && attempts.first?.failed == true)
        if vanishes { #expect(attempts.last?.windowNumber == 7 && attempts.last?.failed == false) }
        #expect(review.finalState.kind == .keyframe)
    }

    @Test func windowSelectionUsesTheLargestDocumentAndRejectsDecorationsAndForeignOwners() {
        let decoration = InteractionWindow(processID: 42, number: 34304, title: nil, layer: 0,
                                           frame: CGRect(x: 0, y: 0, width: 66, height: 20))
        let document = InteractionWindow(processID: 42, number: 7, title: "Edit", layer: 0, frame: window.frame)
        let foreign = InteractionWindow(processID: 99, number: 8, title: "Other", layer: 0, frame: window.frame)
        let listed = [foreign, decoration, document]
        #expect(NativeHumanSceneReader.actionWindow(nil, menuBar: false, in: listed, processID: 42) == document)
        #expect(NativeHumanSceneReader.actionWindow(foreign, menuBar: false, in: listed, processID: 42) == document)
        #expect(NativeHumanSceneReader.frontWindows(in: listed, processID: 42) == [document])
        #expect(NativeHumanSceneReader.frontWindows(in: [foreign, decoration], processID: 42).isEmpty)
    }

    @Test func finalReadIncludesTheDocumentWhenOnlyItsPanelIsOnScreen() async throws {
        let panel = InteractionWindow(processID: 42, number: 19, title: "Panel", layer: 3,
                                      frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let document = InteractionWindow(processID: 42, number: 7, title: "Edit", layer: 0, frame: window.frame)
        let reader = Reader(listedWindows: [panel], allWindows: [panel, document])
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        let review = try await consumer.finish()
        #expect(await reader.windows == [19, 7])
        #expect(try review.finalState.text().contains("window #7") == true)
    }

    @Test func finalReadSkipsAPanelThatIsOffScreenAtHandBack() async throws {
        // A panel the application hides when it loses activation is listed but cannot be captured.
        let panel = InteractionWindow(processID: 42, number: 19, title: "Panel", layer: 3,
                                      frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let document = InteractionWindow(processID: 42, number: 7, title: "Edit", layer: 0, frame: window.frame)
        let reader = Reader(failingWindows: [19], listedWindows: [document], allWindows: [panel, document])
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        let review = try await consumer.finish()
        #expect(await reader.windows == [7])
        #expect(review.finalState.kind == .keyframe)
        #expect(try !review.finalState.text().contains("read failed"))
    }

    @Test(arguments: [false, true])
    func timingHooksPreserveResultsAndRecordFailedStages(fails: Bool) async throws {
        let timing = NativeHumanSceneReader.Timing()
        #expect(timing.milliseconds.isEmpty)
        let base = StageReader(fails: fails)
        let pipeline = ScenePipeline(text: base, augmentation: base, timingHook: {
            NativeHumanSceneReader.Timing.current?.record($0, duration: $1)
        })
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let descriptor = ScenePipeline.Window(bundleID: "test", appName: "Test", title: "",
                                              processID: 42, frame: window.frame, windowNumber: 7)
        do {
            let scene = try await NativeHumanSceneReader.Timing.$current.withValue(timing) {
                try await pipeline.perceive(image, of: descriptor)
            }
            #expect(!fails && scene.elements.first?.label == "cancellable")
        } catch { #expect(fails && error is CocoaError) }
        #expect(timing.diagnostic.contains("capture n/a"))
        #expect(!timing.diagnostic.contains("OCR n/a") && !timing.diagnostic.contains("AX n/a"))
        if !fails {
            let recorded = timing.milliseconds
            let first = NativeHumanSceneReader.Timing(), second = NativeHumanSceneReader.Timing()
            async let one = NativeHumanSceneReader.Timing.$current.withValue(first) {
                try await pipeline.perceive(image, of: descriptor)
            }
            async let two = NativeHumanSceneReader.Timing.$current.withValue(second) {
                try await pipeline.perceive(image, of: descriptor)
            }
            _ = try await (one, two)
            #expect(first.milliseconds["OCR"] != nil && second.milliseconds["OCR"] != nil)
            #expect(first.milliseconds["AX"] != nil && second.milliseconds["AX"] != nil)
            #expect(timing.milliseconds == recorded)
            #expect(NativeHumanSceneReader.Timing.current == nil)
        }
    }

    private struct StageReader: TextRecognizing, SceneAugmenting {
        let fails: Bool

        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            #expect(accuracy == .fast)
            if fails { throw CocoaError(.fileReadUnknown) }
            return [.init(text: "sync", pixelBox: .zero)]
        }

        func recognizeTextCancellably(in image: CGImage, accuracy: TextRecognitionAccuracy) async throws -> [RecognizedText] {
            #expect(accuracy == .accurate)
            if fails { throw CocoaError(.fileReadUnknown) }
            return [.init(text: "cancellable", pixelBox: .zero)]
        }

        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            #expect(processID == 42 && windowFrame.width == 800)
            if fails { throw CocoaError(.fileReadUnknown) }
            return .none
        }

        func augmentation(for processID: pid_t, windowNumber: Int, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            #expect(windowNumber == 7)
            return try await augmentation(for: processID, windowFrame: windowFrame)
        }
    }

    @Test func slowReadKeepsLatestPendingStateAndCompletesEveryActionInOrder() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(holdFirst: true)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        try await append(1, to: consumer, intervention: intervention)
        await reader.waitForFirst()
        for sequence in 2...5 { try await append(UInt64(sequence), to: consumer, intervention: intervention) }
        await reader.release()
        let review = try await consumer.finish()
        #expect(review.findings.map(\.kind) == [.keyframe, .covered, .covered, .covered, .changes])
        #expect(review.findings.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(review.findings.map(\.coveredBySequence) == [nil, 5, 5, 5, nil])
        #expect(review.findings.map(\.inputDuringRead) == [true, false, false, false, false])
        #expect(review.findings.allSatisfy { $0.mode == .textOnly })
        #expect(review.finalState.mode == .full)
        #expect(await reader.modes == [.textOnly, .textOnly, .full, .full])
        #expect(await reader.windows == [7, 7, 19, 7])
        #expect(review.finalState.kind == .keyframe)
        #expect(await intervention.status().phase == .evaluating)
    }

    @Test func burstsDuringEverySlowReadKeepScenesAndCoverOnlyPendingActions() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let buttons = InteractionButtonState()
        let reader = Reader(heldReads: [1, 2, 3])
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader, buttons: buttons)
        try await append(1, to: consumer, intervention: intervention)
        for read in 1...3 {
            try await reader.waitForRead(read)
            for sequence in (read * 3 - 1)...(read * 3 + 1) {
                buttons.press(processID: 42)
                try await append(UInt64(sequence), to: consumer, intervention: intervention)
                buttons.release()
            }
            await reader.release()
        }
        let review = try await consumer.finish()
        #expect(review.findings.map(\.sequence) == Array(1...10).map(UInt64.init))
        #expect(review.findings.map(\.kind) == [
            .keyframe, .covered, .covered, .changes, .covered, .covered, .changes, .covered, .covered, .changes
        ])
        #expect(review.findings.map(\.coveredBySequence) == [nil, 4, 4, nil, 7, 7, nil, 10, 10, nil])
        #expect(review.findings.map(\.inputDuringRead) == [true, false, false, true, false, false, true, false, false, false])
        #expect(review.findings.map(\.baselineSequence) == [nil, nil, nil, 1, nil, nil, 4, nil, nil, 7])
        #expect(await reader.windows == [7, 7, 7, 7, 19, 7])
        #expect(await reader.modes == [.textOnly, .textOnly, .textOnly, .textOnly, .full, .full])
        #expect(review.findings.filter { $0.coveredBySequence == nil }.allSatisfy { $0.compressedBytes > 0 })
        #expect(review.finalState.kind == .keyframe && !review.finalState.inputDuringRead)
        #expect(try review.finalState.text().contains("Full Mix"))
        #expect(await intervention.status().analyzedCount == 10)
    }

    @Test func inputBeforeCaptureChangesAttributionAndSelectedWindow() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(holdFirstListing: true)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        try await append(1, to: consumer, intervention: intervention)
        try await reader.waitForListing()
        try await append(2, window: 19, to: consumer, intervention: intervention)
        await reader.release()
        let review = try await consumer.finish()
        #expect(review.findings.map(\.kind) == [.covered, .keyframe])
        #expect(review.findings.map(\.coveredBySequence) == [2, nil])
        #expect(review.findings[1].windowNumber == 19)
        #expect(review.findings.allSatisfy { !$0.inputDuringRead })
        #expect(await reader.windows == [19, 19, 7])
    }

    @Test(arguments: [false, true])
    func failedCoalescedReadDoesNotClaimCoverage(byteBudget: Bool) async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: byteBudget ? 1 : 100_000)
        let buttons = InteractionButtonState()
        buttons.press(processID: 42)
        let reader = Reader(failFirst: !byteBudget)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader, buttons: buttons)
        for sequence in 1...3 { try await append(UInt64(sequence), to: consumer, intervention: intervention) }
        buttons.release()
        let review = try await consumer.finish()
        #expect(review.findings.map(\.kind) == [.superseded, .superseded, .failed])
        #expect(review.findings.allSatisfy { $0.coveredBySequence == nil })
        #expect(review.findings[2].reason == (byteBudget ? .byteBudget : .read))
        #expect(await reader.windows == [7, 19, 7])
        #expect(await intervention.status().phase == .evaluating)
    }

    @Test func heldDragDefersReadsUntilReleaseIncludingFinalRead() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let buttons = InteractionButtonState()
        buttons.press(processID: 42)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader, buttons: buttons)
        try await append(1, to: consumer, intervention: intervention)
        try await append(2, to: consumer, intervention: intervention)
        let finishing = Task { try await consumer.finish() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await reader.windows.isEmpty)
        buttons.release()
        let review = try await finishing.value
        #expect(review.findings.map(\.kind) == [.covered, .keyframe])
        #expect(await reader.windows == [7, 19, 7])
    }

    @Test func windowsHaveIndependentKeyframesAndLaterDifferences() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(unchanged: true)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        for (sequence, number) in [(1, 7), (2, 19), (3, 7)] {
            try await append(UInt64(sequence), window: number, to: consumer, intervention: intervention)
            while await intervention.status().analyzedCount < sequence { await Task.yield() }
        }
        let review = try await consumer.finish()
        #expect(review.findings.map(\.kind) == [.keyframe, .keyframe, .unchanged])
        #expect(review.findings.map(\.windowNumber) == [7, 19, 7])
        #expect(review.findings.map(\.baselineSequence) == [nil, nil, 1])
        #expect(await reader.modes == [.textOnly, .textOnly, .textOnly, .full, .full])
        #expect(try review.finalState.text().contains("Full Mix"))
        #expect(try !review.findings[0].text().contains("Full Mix"))
        #expect(try review.findings[2].text().contains("Unchanged since revision 1"))
    }

    @Test func failedReadIsACompleteFindingAndFinalReadStillRuns() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(failFirst: true)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        try await append(1, to: consumer, intervention: intervention)
        let review = try await consumer.finish()
        #expect(review.findings.first?.kind == .failed)
        #expect(review.finalState.kind == .keyframe)
        #expect(await intervention.status().phase == .evaluating)
    }

    /// The read taken as control passes reaches the final read's provenance: the "before" of structural effects.
    @Test func theInitialReadIsKeptWhenNoInputArrivesDuringIt() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        await consumer.beginInitialRead()
        let review = try await consumer.finish()
        #expect(review.finalState.provenance?.initialStructure?.windows.first?.number == 7)
    }

    /// Input that arrives while the initial read runs makes it a mix of before and after: it is not kept.
    @Test func theInitialReadIsDroppedWhenInputArrivesDuringIt() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader()
        await reader.delayStructure(.milliseconds(200))
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        await consumer.beginInitialRead()
        try await append(1, to: consumer, intervention: intervention)
        let review = try await consumer.finish()
        #expect(review.finalState.provenance?.initialStructure == nil)
    }

    /// When the person pauses after a read, the windows are read again; new input cancels a pending one.
    @Test func aPauseAfterAReadReadsTheWindowsAgain() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        try await append(1, to: consumer, intervention: intervention)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await reader.structureCalls == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // The read ended; give the consumer the moment it takes to keep it before input ends.
        try await Task.sleep(for: .milliseconds(100))
        let review = try await consumer.finish()
        #expect(review.finalState.provenance?.settled?.map(\.sequence) == [1])
    }

    @Test func emptyEpisodeStillReadsTheCurrentFrontWindow() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        let review = try await consumer.finish()
        #expect(review.findings.isEmpty)
        #expect(await reader.windows == [19, 7])
        #expect(await intervention.status().phase == .evaluating)
    }

    @Test func exhaustedByteBudgetKeepsFailureFindingsWithoutBlockingReview() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 1)
        let reader = Reader()
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        try await append(1, to: consumer, intervention: intervention)
        let review = try await consumer.finish()
        #expect(review.findings.first?.reason == .byteBudget)
        #expect(review.finalState.reason == .byteBudget)
        #expect(await reader.windows == [7, 19, 7])
        #expect(await intervention.status().retainedBytes <= 1)
        #expect(await intervention.status().phase == .evaluating)
    }

    @Test func realisticCompactTextCompressesAndRoundTrips() throws {
        let line = "[control] Track 01 volume id:'control|track 01 volume' @0.20,0.35 {Mix / Audio Tracks} value: 0.0 dB\n"
        let text = String(repeating: line, count: 380)
        let finding = try HumanSceneFinding(sequence: 1, kind: .keyframe, text: text, readMilliseconds: 12)
        #expect(finding.rawBytes > 35_000)
        #expect(finding.compressedBytes > 0 && finding.compressedBytes < 10_000)
        #expect(try finding.text() == text)
        print("Synthetic compact fixture: raw \(finding.rawBytes) bytes, LZFSE \(finding.compressedBytes) bytes")
    }

    @Test(arguments: ["secure role", "secure subrole", "reserved", "unreadable", "ordinary"])
    func protectedValuesAreRefusedBeforeTheValueClosure(scenario: String) {
        var readValue = false
        let result: String? = AccessibilityValueReading.read(
            isReservedLabel: { $0 == "Password" },
            attribute: { name in
                if name == "AXRole" { return scenario == "secure role" ? "AXSecureTextField" : "AXTextField" }
                if name == "AXSubrole" {
                    if scenario == "secure subrole" { return "AXSecureTextField" }
                    return scenario == "unreadable" ? nil : ""
                }
                return name == "AXTitle" && scenario == "reserved" ? "Password" : nil
            },
            value: { readValue = true; return "field contents" })
        #expect(readValue == (scenario == "ordinary"))
        #expect(result == (scenario == "ordinary" ? "field contents" : nil))
    }

    @Test func diagnosticValuesDoNotEraseDigitsFromOtherText() {
        let scene = SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "session-1031",
            viewportPixelSize: .init(width: 310, height: 243), elements: [
                .init(id: "count", kind: .control, label: "Number of 1 tracks",
                      bounds: .init(x: 0, y: 0, width: 1, height: 1), value: "1")])
        for text in ["1|1|000", "310x243", "Number of 1 tracks", "session-1031", #""session-1031""#, " = 1|1|000 @0,0"] {
            #expect(HumanInterventionConsumer.diagnosticDifference(text, before: scene, after: scene) == text)
        }
        #expect(HumanInterventionConsumer.diagnosticDifference("1", before: scene, after: scene) == "[withheld]")
        #expect(HumanInterventionConsumer.diagnosticDifference(
            #"= "1"  (was "1")"#, before: scene, after: scene) == #"= "[withheld]"  (was "[withheld]")"#)
    }

    @Test(arguments: ["1", "12", "session-1031", "a\"b\\c"])
    func diagnosticSecretsUseFragmentsOnlyForLongValues(value: String) {
        let scene = SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Edit",
            viewportPixelSize: .init(width: 310, height: 243), elements: [
                .init(id: "token", kind: .control, label: "Session token",
                      bounds: .init(x: 0, y: 0, width: 1, height: 1), value: value)])
        let fragment = "prefix \(value) suffix"
        let diagnostic = HumanInterventionConsumer.diagnosticDifference(fragment, before: scene, after: scene)
        #expect(diagnostic == (value.count <= 2 ? fragment : "prefix [withheld] suffix"))
        let quoted = "= " + String(reflecting: value)
        #expect(HumanInterventionConsumer.diagnosticDifference(quoted, before: scene, after: scene)
            == #"= "[withheld]""#)
    }

    @Test(arguments: ["Cello", "1", "12", "Cello {solo}", "Cello: solo", "  Cello  ", "line\nbreak"])
    func diagnosticCompactValuesAreWithheld(value: String) {
        let before = SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Edit",
            viewportPixelSize: .init(width: 310, height: 243), elements: [
                .init(id: "name", kind: .control, label: "Track name",
                      bounds: .init(x: 0, y: 0, width: 1, height: 1), value: "Violin")])
        var after = before
        after.elements[0].value = value
        let difference = SceneChanges.text(from: before, to: after, since: 1)
        let diagnostic = HumanInterventionConsumer.diagnosticDifference(difference, before: before, after: after)
        #expect(!diagnostic.contains("Violin"))
        #expect(diagnostic.components(separatedBy: "[withheld]").count == 3, "\(diagnostic)")
    }

    private struct FixtureText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            ["New Paths", "Create", "1", "new", "Mono", "type", "Bus", "Cancel", "Create"].enumerated().map {
                .init(text: $0.element, pixelBox: CGRect(x: 10 + $0.offset * 45, y: 40, width: 30, height: 12))
            }
        }
    }

    @Test(arguments: [ProductionPerception.Mode.full, .textOnly])
    func sceneStageFixture(mode: ProductionPerception.Mode) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Tests/Perception/PerceptionBoundaryTests/Fixtures/NewPathsMono.png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let setup = NativeHumanSceneReader.Timing()
        _ = ProductionPerception.pipeline(mode: mode, timingHook: { setup.record($0, duration: $1) })
        print("scene stage fixture \(mode.rawValue) setup once: \(setup.diagnostic)")
        let pipeline = ScenePipeline(text: FixtureText(),
                                     regions: mode == .full ? ConnectedComponentSegmenter() : nil,
                                     regionFilter: mode == .full ? MediaRegionFilter() : nil,
                                     sections: mode == .full ? ColorSectionDetector() : nil,
                                     augmentation: StageReader(fails: false), timingHook: {
                                         NativeHumanSceneReader.Timing.current?.record($0, duration: $1)
                                     })
        for iteration in 0..<5 {
            let timing = NativeHumanSceneReader.Timing()
            let started = ContinuousClock.now
            let pixels = try await NativeHumanSceneReader.Timing.$current.withValue(timing) {
                try await pipeline.perceive(image, of: .init(bundleID: "test", appName: "Mixer", title: "Edit",
                                                            processID: 42, frame: window.frame, windowNumber: 7))
            }
            timing.record(.perception, since: started)
            #expect(timing.milliseconds["pipeline init (includes Vision)"] == nil)
            #expect(pixels.elements.contains { $0.label.contains("New Paths") })
            if mode == .textOnly { #expect(pixels.elements.allSatisfy { $0.kind != .icon }) }
            if iteration == 4 { print("scene stage fixture \(mode.rawValue) output:\n" + pixels.text()) }
            var scene = pixels
            scene.elements += (0..<380).map { index in
                .init(id: "track-\(index)", kind: .control, label: "Track \(index) volume",
                      bounds: .init(x: 0.2, y: Double(index % 100) / 100, width: 0.2, height: 0.01),
                      role: "AXTextField", value: "0.0 dB", container: "Mix / Audio Tracks")
            }
            let kept = timing.measure(.sceneMinimization) { HumanInterventionConsumer.minimized(scene) }
            let text = timing.measure(.rendering) { kept.text() }
            var after = kept
            after.elements[after.elements.count - 1].value = "1"
            let difference = timing.measure(.difference) { SceneChanges.text(from: kept, to: after, since: 1) }
            let diagnostic = timing.measure(.diagnostics) {
                HumanInterventionConsumer.diagnosticDifference(difference, before: kept, after: after)
            }
            #expect(!diagnostic.contains("0.0 dB"))
            let minimized = timing.measure(.textMinimization) { ValueMinimization().minimize(text: text).0 }
            let finding = try timing.measure(.compression) {
                try HumanSceneFinding(sequence: 1, kind: .keyframe, text: minimized, readMilliseconds: 0)
            }
            #expect(try finding.text() == minimized)
            print("scene stage synthetic fixture \(mode.rawValue) \(iteration), \(image.width)x\(image.height), raw \(finding.rawBytes): \(timing.diagnostic); wall \(started.duration(to: .now))")
        }
    }

    @Test func retainedScenesMinimizeSecretsAndDiagnosticsWithholdOrdinaryValues() {
        let before = SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Edit",
            viewportPixelSize: .init(width: 800, height: 600), elements: [
                .init(id: "password", kind: .control, label: "Password",
                      bounds: .init(x: 0, y: 0, width: 0.2, height: 0.1), value: "private-contents"),
                .init(id: "name", kind: .control, label: "Track name",
                      bounds: .init(x: 0, y: 0.2, width: 0.2, height: 0.1), value: "Violin")])
        let kept = HumanInterventionConsumer.minimized(before)
        #expect(!kept.text().contains("private-contents"))
        #expect(kept.text().contains("Violin"))
        var after = kept
        after.elements[1].value = "Cello"
        let difference = SceneChanges.text(from: kept, to: after, since: 1)
        let diagnostic = HumanInterventionConsumer.diagnosticDifference(difference, before: kept, after: after)
        #expect(diagnostic.contains("Track name"))
        #expect(!diagnostic.contains("Violin") && !diagnostic.contains("Cello"), "\(diagnostic)")
        #expect(diagnostic.contains("[withheld]"))
    }

    @Test func aReadSpanningADragIsKeptWhileFurtherReadsWaitForRelease() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let buttons = InteractionButtonState()
        let reader = Reader(holdFirst: true)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader, buttons: buttons)
        try await append(1, to: consumer, intervention: intervention)
        await reader.waitForFirst()
        buttons.press(processID: 42)
        await reader.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await intervention.status().analyzedCount == 1)
        #expect(await reader.windows == [7])
        buttons.release()
        let review = try await consumer.finish()
        #expect(review.findings.first?.kind == .keyframe)
        #expect(review.findings.first?.inputDuringRead == true)
        #expect(!review.finalState.inputDuringRead)
        #expect(await reader.windows == [7, 19, 7])
    }

    @Test func finalReadPreservesSuccessfulSurfacesBesideAFailedSurface() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(finalWindows: [19, 20], failingWindows: [19])
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        let review = try await consumer.finish()
        #expect(await reader.windows == [19, 20])
        #expect(review.finalState.kind == .failed && review.finalState.reason == .read)
        let text = try review.finalState.text()
        #expect(text.contains("window #19: read failed"))
        #expect(text.contains("window #20") && text.contains("Track"))
        #expect(await intervention.status().phase == .evaluating)
    }

    @Test func consumerCancellationBlocksItsLeaseInsteadOfCreatingAReview() async throws {
        let intervention = try HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>(
            maximumEvents: 20, maximumRetainedBytes: 100_000)
        let reader = Reader(cancelFirst: true)
        let consumer = HumanInterventionConsumer(intervention: intervention, window: window, reader: reader,
                                                 buttons: InteractionButtonState())
        try await append(1, to: consumer, intervention: intervention)
        await #expect(throws: CancellationError.self) { try await consumer.finish() }
        #expect(await intervention.status().phase == .blocked)
        #expect(await intervention.status().analyzedCount == 0)
    }

    @Test func physicalReleaseIsConsultedOnlyAfterTheListenerStops() {
        let buttons = InteractionButtonState(isPhysicallyPressed: { false })
        buttons.press(processID: 42)
        #expect(buttons.snapshot().processID == 42)
        buttons.finishListening()
        #expect(buttons.snapshot().processID == nil)
    }

    private actor Reader: HumanSceneReading {
        var windows: [Int] = []
        var modes: [ProductionPerception.Mode] = []
        let finalWindows: [Int]
        var listedWindows: [InteractionWindow]?
        let allWindows: [InteractionWindow]?
        let vanishingWindows: Set<Int>
        let failingWindows: Set<Int>
        let cancelFirst: Bool
        let holdFirst: Bool
        let heldReads: Set<Int>
        let holdFirstListing: Bool
        var listings = 0
        var activeReads = 0
        let failFirst: Bool
        let unchanged: Bool
        var entered: CheckedContinuation<Void, Never>?
        var blocked: CheckedContinuation<Void, Never>?

        init(holdFirst: Bool = false, failFirst: Bool = false, unchanged: Bool = false,
             finalWindows: [Int] = [19, 7], failingWindows: Set<Int> = [], cancelFirst: Bool = false,
             listedWindows: [InteractionWindow]? = nil, vanishingWindows: Set<Int> = [],
             heldReads: Set<Int> = [], holdFirstListing: Bool = false, allWindows: [InteractionWindow]? = nil) {
            self.allWindows = allWindows
            self.heldReads = heldReads
            self.holdFirstListing = holdFirstListing
            self.vanishingWindows = vanishingWindows
            self.listedWindows = listedWindows
            self.finalWindows = finalWindows
            self.failingWindows = failingWindows
            self.cancelFirst = cancelFirst
            self.holdFirst = holdFirst
            self.failFirst = failFirst
            self.unchanged = unchanged
        }

        func waitForFirst() async {
            if !windows.isEmpty { return }
            await withCheckedContinuation { entered = $0 }
        }

        /// Structural reads alone (when control passes, when the person pauses): counted, each `structureDelay` long.
        var structureCalls = 0
        var structureDelay: Duration = .zero
        func delayStructure(_ delay: Duration) { structureDelay = delay }
        func structure(processID: Int32, seconds: Double) async -> InteractionStructuralRead {
            structureCalls += 1
            if structureDelay > .zero { try? await Task.sleep(for: structureDelay) }
            return InteractionStructuralRead(processID: processID, interval: .init(start: 0, end: 0.1),
                                             windows: [.init(number: 7, title: "Mix")])
        }

        func waitForRead(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while windows.count < count, ContinuousClock.now < deadline { await Task.yield() }
            try #require(windows.count == count)
        }

        func waitForListing() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while listings == 0, ContinuousClock.now < deadline { await Task.yield() }
            try #require(listings == 1)
        }

        func release() { blocked?.resume(); blocked = nil }

        private func checkExecutor() { #expect(!Thread.isMainThread) }

        func scene(window: InteractionWindow, mode: ProductionPerception.Mode,
                   timing: NativeHumanSceneReader.Timing) async throws -> SceneSnapshot {
            checkExecutor()
            timing.beginSurface(processID: window.processID, windowNumber: window.number, mode: mode.rawValue)
            activeReads += 1
            defer { activeReads -= 1 }
            #expect(activeReads == 1)
            windows.append(window.number)
            modes.append(mode)
            if vanishingWindows.contains(window.number) {
                listedWindows?.removeAll { $0.number == window.number }
            }
            entered?.resume(); entered = nil
            if (windows.count == 1 && holdFirst) || heldReads.contains(windows.count) {
                await withCheckedContinuation { blocked = $0 }
            }
            if windows.count == 1, cancelFirst { throw CancellationError() }
            if (windows.count == 1 && failFirst) || failingWindows.contains(window.number) {
                throw CocoaError(.fileReadUnknown)
            }
            return SceneSnapshot(bundleID: "test.mixer", appName: "Mixer", windowTitle: mode == .full ? "Full Mix" : "Mix",
                viewportPixelSize: .init(width: 800, height: 600),
                elements: [.init(id: "track", kind: .control, label: "Track",
                                 bounds: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                                 value: unchanged ? "0" : String(windows.count))])
        }

        func windows(processID: Int32) async throws -> [InteractionWindow] {
            listings += 1
            if listings == 1, holdFirstListing { await withCheckedContinuation { blocked = $0 } }
            if let listedWindows { return listedWindows }
            return finalWindows.map {
                .init(processID: processID, number: $0, title: "Current dialog", layer: 0,
                      frame: CGRect(x: 0, y: 0, width: $0 == 7 || $0 == 20 ? 800 : 400, height: 300))
            }
        }

        func finalWindows(processID: Int32) async throws -> [InteractionWindow] {
            if let allWindows { return allWindows }
            return try await windows(processID: processID)
        }
    }
}
