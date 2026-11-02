//
//  HumanInterventionRecorderTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import CoreGraphics
import Engine
import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore
import Testing
@testable import SeatBroker

@MainActor
@Suite
struct HumanInterventionRecorderTests {
    private let window = LentWindow(windowNumber: 7, processID: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    private func event(_ kind: InteractionEvent.Kind, _ sequence: UInt64, pid: Int32 = 42, layer: Int = 0,
                       number: Int? = 7, title: String = "Edit: Test",
                       point: CGPoint = CGPoint(x: 10, y: 100)) -> InteractionEvent {
        .init(kind: kind, timestamp: Date(), startedAt: Double(sequence), endedAt: Double(sequence) + 0.1,
              precedingRevision: sequence - 1, revision: sequence, point: point,
              window: number.map { .init(processID: pid, number: $0, title: title, layer: layer, frame: window.frame) },
              processID: pid, deltaX: 3, deltaY: 5, sequence: sequence,
              gap: kind == .gap ? .init(firstSequence: 8, lastSequence: 9, lostCritical: 1, lostCoalescible: 1) : nil,
              keyCode: 1, modifiers: .command, endPoint: CGPoint(x: 30, y: 40), clickCount: 2)
    }

    @Test func recordsOrderedActionsFiltersOtherAppsAndKeepsGaps() async throws {
        let source = Source()
        let reader = Reader()
        var failures = 0
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
                                                     commandName: { _ in "⌘S" }, onFailure: { _ in failures += 1 })
        source.send([event(.click, 1), event(.click, 2, pid: 99), event(.hover, 3), event(.focus, 4),
                     event(.rightClick, 5), event(.scroll, 6), event(.drag, 7), event(.gap, 9, pid: 0),
                     event(.shortcut, 10), event(.typing, 11)])
        await recorder.processing?.value
        #expect(failures == 0)
        #expect(recorder.droppedOtherAppEvents == 1)
        #expect(recorder.history.map(\.kind) == [.click, .rightClick, .scroll, .drag, .gap, .shortcut, .typing])
        #expect(recorder.history.map(\.sourceSequence) == [1, 5, 6, 7, 9, 10, 11])
        #expect(recorder.history[0].clickCount == 2)
        #expect(recorder.history[2].deltaY == 5)
        #expect(recorder.history[3].endPoint == CGPoint(x: 30, y: 40))
        #expect(recorder.history[3].endElement?.label == "End")
        #expect(recorder.history[4].gap?.lostCritical == 1)
        #expect(recorder.history[5].commandName == "⌘S")
        let typing = recorder.history[6]
        #expect(typing.commandName == nil && typing.keyCode == nil && typing.modifiers == nil)
        #expect(typing.point == nil && typing.endPoint == nil && typing.clickCount == nil)
        #expect(typing.element?.label == "Track name")
        #expect(typing.element?.isProtected == false)
        #expect(await reader.requested.contains("AXValue") == false)
        #expect(!String(reflecting: typing).contains("typed-secret"))
        for expected in recorder.history {
            let item = try #require(await recorder.intervention.next())
            #expect(item.payload.sourceSequence == expected.sourceSequence)
            try await recorder.intervention.complete(item, with: HumanSceneFinding(sequence: item.sequence, kind: .superseded))
        }
        let status = await recorder.intervention.status()
        #expect(status.recordedCount == 7 && status.retainedBytes > 0)
        await recorder.stop()
        #expect(source.stops == 1)
        #expect(await recorder.intervention.status().phase == .closed)
    }

    @Test func protectedTypingHasOnlyItsRoleAndNeverRequestsValue() async throws {
        let source = Source()
        let reader = Reader(secure: true)
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader, onFailure: { _ in })
        source.send([event(.typing, 1)])
        await recorder.processing?.value
        let payload = try #require(recorder.history.first)
        #expect(payload.element?.isProtected == true)
        #expect(payload.element?.role == "AXTextArea")
        #expect(payload.element?.label == nil)
        #expect(!String(reflecting: payload).contains("typed-secret"))
        #expect(await reader.requested.contains("AXValue") == false)
        await recorder.stop()
    }

    @Test func unknownAndReservedFieldsKeepTheirClassificationInTheSummary() async throws {
        for reserved in [false, true] {
            let source = Source()
            let reader = Reader(unknown: !reserved, label: reserved ? "Password" : "Track name")
            let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader, onFailure: { _ in })
            source.send([event(.typing, 1)])
            await recorder.processing?.value
            let payload = try #require(recorder.history.first)
            #expect(payload.element?.isProtected == reserved)
            #expect(payload.element?.label == nil)
            #expect(payload.diagnostic.contains(reserved ? "protected field" : "unknown role"))
            #expect(!payload.diagnostic.contains("Password"))
            #expect(await reader.requested.contains("AXValue") == false)
            await recorder.stop()
        }
    }

    @Test(arguments: [Int32(42), Int32(99), nil])
    func menuBarRequiresGeometryAndAnItemOfTheFrontmostLentApp(frontmost: Int32?) async throws {
        let source = Source()
        let reader = Reader()
        let recorder = try HumanInterventionRecorder(
            window: window, source: source, reader: reader, frontmostProcessID: { frontmost },
            isMenuBarPoint: { $0.y < 25 },
            onFailure: { _ in Issue.record("Unexpected recording failure") }
        )
        source.send([event(.click, 1, pid: 464, number: nil, point: CGPoint(x: 10, y: 20)),
                     event(.click, 2, layer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                           point: CGPoint(x: 10, y: 100)),
                     event(.click, 3, pid: 99, point: CGPoint(x: 10, y: 100)),
                     event(.click, 4, pid: 464, number: nil, point: CGPoint(x: 750, y: 20)),
                     event(.scroll, 5, pid: 464, number: nil),
                     event(.click, 6, pid: 464, layer: Int(CGWindowLevelForKey(.mainMenuWindow)),
                           point: CGPoint(x: 10, y: 100)),
                     event(.click, 7, point: CGPoint(x: 750, y: 20))])
        await recorder.processing?.value
        let kept = frontmost == 42
        #expect(recorder.history.map(\.sourceSequence) == (kept ? [1, 2] : [2]))
        #expect(recorder.history.allSatisfy { $0.processID == 42 })
        #expect(recorder.droppedOtherAppEvents == (kept ? 5 : 6))
        #expect(recorder.droppedEventCounts[.init(kind: .click, processID: 464, layer: nil)] == (kept ? 1 : 2))
        if kept {
            #expect(recorder.history.first?.element?.role == "AXMenuBarItem")
            #expect(recorder.history.first?.element?.label == "File")
        }
        #expect(await reader.menuBarReads == (kept ? 3 : 0))
        await recorder.stop()
    }

    @Test func menuBarStripUsesEachScreensTopEdgeAndHiddenBarHeight() {
        let frame = CGRect(x: -1200, y: 300, width: 1200, height: 900)
        let visible = CGRect(x: -1200, y: 300, width: 1200, height: 872)
        let bar = HumanInterventionRecorder.menuBarFrame(
            screenFrame: frame, visibleFrame: visible, primaryScreenMaxY: 1000, fallbackHeight: 24)
        #expect(bar == CGRect(x: -1200, y: -200, width: 1200, height: 28))
        #expect(bar.contains(CGPoint(x: -500, y: -190)))
        #expect(!bar.contains(CGPoint(x: -500, y: -171)))
        let hidden = HumanInterventionRecorder.menuBarFrame(
            screenFrame: frame, visibleFrame: frame, primaryScreenMaxY: 1000, fallbackHeight: 24)
        #expect(hidden == CGRect(x: -1200, y: -200, width: 1200, height: 24))
    }

    @Test(arguments: ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"], [true, false])
    func missingFocusUsesTheClickedFieldAndItsCapturedWindow(role: String, nilFocus: Bool) async throws {
        let source = Source()
        let reader = Reader(emptyFocus: true, nilFocus: nilFocus, clickRole: role)
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            commandName: { _ in "Return" }, onFailure: { _ in Issue.record("Unexpected failure") })
        source.send([event(.click, 1, title: "New Tracks"),
                     event(.click, 2, title: "Changed title", point: CGPoint(x: 30, y: 100)),
                     event(.typing, 3, title: "Changed title"),
                     event(.shortcut, 61, title: "Changed again")])
        await recorder.processing?.value
        #expect(recorder.history.map(\.kind) == [.click, .click, .typing, .shortcut])
        for payload in recorder.history.suffix(2) {
            #expect(payload.element?.role == role)
            #expect(payload.element?.label == "New Track")
            #expect(payload.window?.title == "New Tracks")
            #expect(payload.isTargetInferredFromLastClick)
            #expect(payload.diagnostic.contains("(from last click)"))
        }
        #expect(await reader.requested.contains(where: { $0.hasSuffix("AXValue") }) == false)
        await recorder.stop()
    }

    @Test(arguments: ["other window", "other app", "unknown window", "expired", "nontext", "focused"])
    func clickFallbackRequiresARecentEligibleTarget(scenario: String) async throws {
        let source = Source()
        let reader = Reader(emptyFocus: scenario != "focused", clickRole: scenario == "nontext" ? "AXButton" : "AXTextArea")
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            isMenuBarPoint: { _ in false }, onFailure: { _ in Issue.record("Unexpected failure") })
        var events = [event(.click, 1)]
        if scenario == "other window" || scenario == "other app" || scenario == "unknown window" {
            events.append(event(.click, 2, pid: scenario == "other app" ? 99 : 42,
                                number: scenario == "unknown window" ? nil : 8,
                                point: CGPoint(x: 30, y: 40)))
        }
        events.append(event(.typing, scenario == "expired" ? 62 : 3))
        source.send(events)
        await recorder.processing?.value
        let payload = try #require(recorder.history.last)
        #expect(!payload.isTargetInferredFromLastClick)
        #expect(payload.element?.role == (scenario == "focused" ? "AXTextArea" : nil))
        #expect(payload.window?.title == nil)
        #expect(await reader.requested.contains("AXValue") == false)
        await recorder.stop()
    }

    @Test func protectedClickFallbackRetainsOnlyTheRole() async throws {
        let source = Source()
        let reader = Reader(secure: true, emptyFocus: true, clickRole: "AXTextArea")
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            onFailure: { _ in Issue.record("Unexpected failure") })
        source.send([event(.click, 1, title: "Private window"), event(.typing, 2)])
        await recorder.processing?.value
        let payload = try #require(recorder.history.last)
        #expect(payload.isTargetInferredFromLastClick)
        #expect(payload.element?.isProtected == true)
        #expect(payload.element?.role == "AXTextArea")
        #expect(payload.element?.label == nil && payload.element?.subrole == nil)
        #expect(payload.window == nil)
        #expect(!payload.diagnostic.contains("Private window"))
        #expect(await reader.requested.contains(where: { $0.hasSuffix("AXValue") }) == false)
        await recorder.stop()
    }

    @Test func pictureAfterDeadlineIsDiscardedWithoutReorderingEntries() async throws {
        let source = Source()
        let reader = Reader(holdPicture: true)
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader, onFailure: { _ in })
        let started = ContinuousClock.now
        source.send([event(.click, 1), event(.typing, 2), event(.rightClick, 3)])
        await recorder.processing?.value
        #expect(started.duration(to: .now) >= .milliseconds(600))
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(recorder.history.map(\.sourceSequence) == [1, 2, 3])
        #expect(recorder.history.allSatisfy { $0.picture == nil })
        #expect(await reader.pictureCalls == 1)
        await recorder.stop()
        await reader.releasePicture()
        #expect(recorder.history.isEmpty)
    }

    @Test func pictureAfterMetadataButBeforeDeadlineIsKept() async throws {
        let source = Source()
        let reader = Reader(pictureDelay: .milliseconds(100))
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            onFailure: { _ in Issue.record("Unexpected recording failure") })
        source.send([event(.click, 1), event(.typing, 2)])
        await recorder.processing?.value
        #expect(recorder.history.map(\.sourceSequence) == [1, 2])
        #expect(recorder.history.first?.picture?.heic.count == 4096)
        #expect(await recorder.intervention.status().retainedBytes >= 4096)
        await recorder.stop()
    }

    @Test func clickBurstSkipsBusyPicturesWithoutDroppingEvents() async throws {
        let source = Source()
        let reader = Reader(pictureDelay: .milliseconds(400))
        var failures = 0
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            onFailure: { _ in failures += 1 })
        let started = ContinuousClock.now
        for sequence in UInt64(1)...20 {
            source.continuation.yield(event(.click, sequence))
            try await Task.sleep(for: .milliseconds(100))
        }
        source.continuation.finish()
        await recorder.processing?.value
        #expect(started.duration(to: .now) < .seconds(4))
        #expect(failures == 0)
        #expect(recorder.history.map(\.sourceSequence) == Array(UInt64(1)...20))
        let pictures = recorder.history.filter { $0.picture != nil }.count
        #expect(pictures > 0 && pictures < 20)
        await recorder.stop()
    }

    @Test func stopDoesNotJoinAnUncooperativePicture() async throws {
        let source = Source()
        let reader = Reader(holdPicture: true)
        var counts: [Int] = []
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            onRecord: { counts.append($0) }, onFailure: { _ in Issue.record("Unexpected recording failure") })
        source.send([event(.click, 1), event(.rightClick, 2)])
        while await reader.pictureCalls == 0 { await Task.yield() }
        let started = ContinuousClock.now
        await recorder.stop()
        #expect(started.duration(to: .now) < .milliseconds(600))
        #expect(counts == [1, 2])
        #expect(await reader.pictureCalls == 1)
        await reader.releasePicture()
    }

    @Test func readyPictureIsImmutableAndChargedToTheQueue() async throws {
        let source = Source()
        let reader = Reader(waitForPicture: true)
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader, onFailure: { _ in })
        source.send([event(.click, 1)])
        await recorder.processing?.value
        let payload = try #require(recorder.history.first)
        #expect(payload.picture?.heic.count == 4096)
        #expect(await recorder.intervention.status().retainedBytes >= 4096)
        #expect(await reader.capturedWindow == window)
        await recorder.stop()
    }

    @Test func pictureUsesTheClickedDialogOfTheLentApplication() async throws {
        let source = Source()
        let reader = Reader(waitForPicture: true)
        let recorder = try HumanInterventionRecorder(
            window: window, source: source, reader: reader, onFailure: { _ in Issue.record("Unexpected failure") })
        source.send([event(.click, 1, number: 19, title: "New Tracks")])
        await recorder.processing?.value
        #expect(await reader.capturedWindow?.windowNumber == 19)
        #expect(await reader.capturedWindow?.processID == 42)
        await recorder.stop()
    }

    @Test(arguments: [true, false])
    func overflowSurfacesAndPreservesAdmittedHistory(eventLimit: Bool) async throws {
        let source = Source()
        var failures = 0
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: Reader(),
            maximumEvents: eventLimit ? 1 : 100, maximumRetainedBytes: eventLimit ? 100_000 : 1,
            onFailure: { _ in failures += 1 })
        source.send([event(.typing, 1), event(.typing, 2)])
        await recorder.processing?.value
        #expect(failures == 1)
        #expect(recorder.history.count == (eventLimit ? 1 : 0))
        #expect(await recorder.intervention.status().phase == .blocked)
        await recorder.stop()
    }

    @Test func pendingInboxOverflowIsReportedInsteadOfEvictingAnAction() async throws {
        let source = Source()
        var failures = 0
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: Reader(),
            pendingEvents: 1, onFailure: { _ in failures += 1 })
        source.send((1...100).map { event(.typing, UInt64($0)) })
        await recorder.processing?.value
        #expect(failures == 1)
        #expect(recorder.history.first?.sourceSequence == 1)
        await recorder.stop()
        #expect(source.stops == 1)
    }

    @Test func stopFlushesTheSourcesLastTypingBurstAndJoinsOnlyOnce() async throws {
        let source = Source()
        source.onStop = [event(.typing, 2)]
        var counts: [Int] = []
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: Reader(),
            onRecord: { counts.append($0) }, onFailure: { _ in Issue.record("Unexpected recording failure") })
        source.continuation.yield(event(.typing, 1))
        async let first: Void = recorder.stop()
        async let second: Void = recorder.stop()
        _ = await (first, second)
        #expect(counts == [1, 2])
        #expect(source.stops == 1)
        #expect(await recorder.intervention.status().phase == .closed)
    }

    @Test func stopFlushesRecordingBeforeFinalReconstructionAndKeepsTheReview() async throws {
        let source = Source()
        source.onStop = [event(.typing, 2)]
        let scenes = SceneReader(source: source)
        let recorder = try HumanInterventionRecorder(
            window: window, source: source, reader: Reader(), sceneReader: scenes,
            onFailure: { _ in Issue.record("Unexpected failure") })
        source.continuation.yield(event(.typing, 1))
        await recorder.stop()
        let review = try #require(recorder.review)
        #expect(review.findings.map(\.sequence) == [1, 2])
        #expect(review.finalState.kind == .keyframe)
        #expect(await recorder.intervention.status().phase == .evaluating)
        #expect(source.stops == 1)
        #expect(await scenes.lastReadAfterStop)
        let reads = await scenes.windowLists
        #expect(reads >= 2)
        await recorder.stop()
        #expect(await scenes.windowLists == reads)
    }

    @Test func inputOnContentAnotherProcessHostsInTheLentWindowIsTheLentApplications() async throws {
        let lent = InteractionWindow(processID: 42, number: 7, title: "Settings", layer: 0, frame: window.frame)
        let hosted = event(.drag, 1, pid: 99, number: nil, point: CGPoint(x: 100, y: 100))
        let attributed = HumanInterventionRecorder.hosted(hosted, in: 42, windows: [lent])
        #expect(attributed?.processID == 42 && attributed?.window?.number == 7 && attributed?.endPoint == hosted.endPoint)
        // Another window over the point, or a window of the routed process there, keeps the routing; keys have no point.
        let other = InteractionWindow(processID: 77, number: 8, title: "Other", layer: 0,
                                      frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let popup = InteractionWindow(processID: 99, number: 9, title: nil, layer: 101, frame: window.frame)
        #expect(HumanInterventionRecorder.hosted(hosted, in: 42, windows: [other, lent]) == nil)
        #expect(HumanInterventionRecorder.hosted(hosted, in: 42, windows: [popup, lent]) == nil)
        // An overlay at a higher layer that the input passed through, over the whole screen, keeps it the lent one's.
        let overlay = InteractionWindow(processID: 77, number: 10, title: nil, layer: 24,
                                        frame: CGRect(x: 0, y: 0, width: 4000, height: 3000))
        #expect(HumanInterventionRecorder.hosted(hosted, in: 42, windows: [overlay, lent])?.window?.number == 7)
        #expect(HumanInterventionRecorder.hosted(event(.typing, 2, pid: 99, number: nil), in: 42, windows: [lent]) == nil)
        let source = Source()
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: Reader(),
                                                     onScreenWindows: { [lent] }, ownProcessID: 5, onFailure: { _ in })
        source.send([hosted, event(.click, 2, pid: 5, number: nil),
                     event(.click, 3, pid: 99, number: nil, point: CGPoint(x: 900, y: 100))])
        await recorder.processing?.value
        #expect(recorder.history.map(\.sourceSequence) == [1])
        #expect(recorder.history.first?.processID == 42 && recorder.history.first?.window?.number == 7)
        #expect(recorder.droppedOtherAppEvents == 2)
        await recorder.stop()
    }

    @Test func pictureRefusesAWindowOfAnotherProcess() {
        let surface = InteractionWindow(processID: 99, number: 19, title: "Other app", layer: 0, frame: .zero)
        #expect(HumanInterventionRecorder.pictureWindow(for: surface, fallback: window) == window)
    }

    @Test(arguments: [false, true])
    func semanticStateNeedsAnUnchangedInputRevision(interrupted: Bool) async throws {
        let source = Source()
        source.observationRevision = 1
        var state = InteractionSemanticSnapshot(processID: 42, interval: .init(start: 1.11, end: 1.13))
        state.focused = .value(0)
        state.elements = [.init(id: 0, window: 7, role: "AXTextField", label: "Name")]
        state.windowTitles = [7: "New Items"]
        let reader = SemanticReader(state: state) { call in if interrupted && call == 2 { source.observationRevision = 3 } }
        let recorder = try HumanInterventionRecorder(window: window, source: source, reader: reader,
            commandName: { _ in "Return" }, onFailure: { _ in Issue.record("Unexpected failure") })
        source.continuation.yield(event(.typing, 1))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.history.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        try #require(recorder.history.count == 1)
        source.observationRevision = 2
        source.send([event(.shortcut, 2)])
        await recorder.processing?.value
        let action = try #require(recorder.history.last?.summaryAction)
        #expect(action.provenance?.interval == .init(start: 2, end: 2.1))
        #expect((action.provenance?.attestedState != nil) == !interrupted)
        if !interrupted {
            #expect(action.role == "AXTextField" && action.label == "Name")
            #expect(HumanInterventionEvidence.action(action) == "Return in text field 'Name' (New Items)")
        }
        await recorder.stop()
    }

    private actor SemanticReader: HumanInteractionReading {
        var calls = 0
        let state: InteractionSemanticSnapshot
        let onRead: @MainActor @Sendable (Int) -> Void
        init(state: InteractionSemanticSnapshot, onRead: @escaping @MainActor @Sendable (Int) -> Void) {
            self.state = state; self.onRead = onRead
        }
        func semantics(processID: Int32, windows: Set<Int>) async -> InteractionSemanticSnapshot? {
            calls += 1
            await onRead(calls)
            var snapshot = state
            snapshot.interval = .init(start: Double(calls) + 0.11, end: Double(calls) + 0.13)
            return snapshot
        }
        func element(at point: CGPoint?, processID: Int32, menuBar: Bool) async -> InteractionElementMetadata? { nil }
        func picture(of window: LentWindow) async -> HumanPreviewControl.RetainedPicture? { nil }
    }

    private actor SceneReader: HumanSceneReading {
        let source: Source
        var windowLists = 0
        var lastReadAfterStop = false
        init(source: Source) { self.source = source }

        func scene(window: InteractionWindow, mode: ProductionPerception.Mode,
                   timing: NativeHumanSceneReader.Timing) async throws -> SceneSnapshot {
            lastReadAfterStop = await source.stops == 1
            return SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Mix",
                          viewportPixelSize: .init(width: 800, height: 600), elements: [])
        }

        func windows(processID: Int32) async throws -> [InteractionWindow] {
            windowLists += 1
            return [.init(processID: processID, number: 7, title: "Mix", layer: 0,
                          frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        }
    }

    private final class Source: HumanInteractionSource {
        let buttons = InteractionButtonState()
        let events: AsyncThrowingStream<InteractionEvent, any Error>
        let continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation
        var observationRevision: UInt64?
        var stops = 0
        var onStop: [InteractionEvent] = []

        init() {
            (events, continuation) = AsyncThrowingStream.makeStream()
        }

        func send(_ events: [InteractionEvent]) {
            for event in events { continuation.yield(event) }
            continuation.finish()
        }

        func stop() async {
            stops += 1
            for event in onStop { continuation.yield(event) }
            continuation.finish()
        }
    }

    private actor Reader: HumanInteractionReading {
        let secure: Bool
        let nilFocus: Bool
        let emptyFocus: Bool
        let clickRole: String?
        let unknown: Bool
        let label: String
        let holdPicture: Bool
        let waitForPicture: Bool
        let pictureDelay: Duration
        var requested: [String] = []
        var pictureCalls = 0
        var menuBarReads = 0
        var capturedWindow: LentWindow?
        var pictureWaiter: CheckedContinuation<Void, Never>?

        init(secure: Bool = false, unknown: Bool = false, emptyFocus: Bool = false, nilFocus: Bool = true,
             clickRole: String? = nil, label: String = "Track name",
             holdPicture: Bool = false, waitForPicture: Bool = false,
             pictureDelay: Duration = .zero) {
            self.nilFocus = nilFocus
            self.emptyFocus = emptyFocus
            self.clickRole = clickRole
            self.secure = secure
            self.unknown = unknown
            self.label = label
            self.holdPicture = holdPicture
            self.waitForPicture = waitForPicture
            self.pictureDelay = pictureDelay
        }

        func element(at point: CGPoint?, processID: Int32, menuBar: Bool) async -> InteractionElementMetadata? {
            #expect(processID == 42)
            if menuBar {
                menuBarReads += 1
                if point?.x != 10 { return nil }
            }
            if emptyFocus, point == nil {
                return nilFocus ? nil : InteractionElementMetadata.read(isReservedLabel: { _ in false }) { _ in nil }
            }
            if waitForPicture {
                // Let the capture task publish its result before metadata finishes.
                try? await Task.sleep(for: .milliseconds(20))
            }
            return InteractionElementMetadata.read(isReservedLabel: { $0 == "Password" }, titleElementAttribute: { key in
                requested.append("label.\(key)")
                return ["AXRole": "AXStaticText", "AXValue": label][key]
            }) { key in
                requested.append(key)
                if unknown { return nil }
                if key == "AXSubrole" { return secure ? "AXSecureTextField" : nil }
                if key == "AXRole" {
                    if menuBar { return "AXMenuBarItem" }
                    if point == nil { return "AXTextArea" }
                    return point?.x == 30 ? "AXButton" : clickRole ?? "AXButton"
                }
                if key == "AXTitle", let point { return menuBar ? "File" : point.x == 30 ? "End" : "New Track" }
                return key == "AXValue" ? "typed-secret" : nil
            }
        }

        func picture(of window: LentWindow) async -> HumanPreviewControl.RetainedPicture? {
            pictureCalls += 1
            capturedWindow = window
            if holdPicture { await withCheckedContinuation { pictureWaiter = $0 } }
            if pictureDelay > .zero { try? await Task.sleep(for: pictureDelay) }
            return .init(heic: Data(repeating: 7, count: 4096), pixelSize: CGSize(width: 800, height: 600),
                         encodedSize: CGSize(width: 800, height: 600))
        }

        func releasePicture() { pictureWaiter?.resume(); pictureWaiter = nil }
    }
}
