//
//  SeatSceneProviderTests.swift
//  Braus
//

import CoreGraphics
import CoreVideo
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCapture
import SeatCore
import SeatDriving
import SeatInput
@testable import SeatSession
import Testing

/// SeatSceneProviderTests keep adoption metadata separate from the title observed after capture.
@MainActor
@Suite("Seat scene window metadata")
struct SeatSceneProviderTests {

    private struct EmptyText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            []
        }
    }

    private final class Windows: WindowListing, @unchecked Sendable {
        var rows: [WindowRow] = []
        var reads = 0
        func windows(ownedBy processID: Int32) throws -> [WindowRow] {
            reads += 1
            return rows
        }
    }

    private struct CaptureAugmentation: SceneAugmenting {
        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            AccessibilityHarvest(elements: [element(value: "geometry-only")], quality: .unknown)
        }

        func augmentation(
            for processID: pid_t, windowNumber: Int, windowFrame: CGRect
        ) async throws -> AccessibilityHarvest {
            AccessibilityHarvest(elements: [element(value: "\(processID):\(windowNumber)")], quality: .unknown)
        }

        private func element(value: String) -> SceneElement {
            SceneElement(
                id: "native-field", kind: .control, label: "Probe Text",
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05),
                role: "AXTextField", value: value
            )
        }
    }

    @Test("the captured recipient reaches native augmentation despite another window sharing its frame")
    func capturedIdentityReachesNativeFacts() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let windows = Windows()
        let number = context.window.id
        let frame = context.window.reference.frame
        windows.rows = [
            WindowRow(layer: 0, frame: frame, title: "Other", number: number + 1),
            WindowRow(layer: 0, frame: frame, title: "Captured", number: number)
        ]
        let provider = SeatSceneProvider(
            target: context.target,
            pipeline: ScenePipeline(text: EmptyText(), augmentation: CaptureAugmentation()),
            windows: windows,
            identity: { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") }
        )
        let scene = try await provider.currentScene(of: context.window.reference.processID)
        #expect(scene.scene.windowTitle == "Captured")
        #expect(scene.scene.elements.first?.value == "\(context.window.reference.processID):\(number)")
    }

    @Test("a display crop follows its recipient while the primary window stays held",
          arguments: [false, true])
    func popupCaptureUsesTheOutstandingRecipient(superseded: Bool) async throws {
        let sensing = FakeSensing()
        let context = try await SmallAuxiliarySurfaceTests.seat(marker: 970, sensing: sensing)
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat)
        _ = try await target.observe()
        let panel = FakeGeometry.reference(
            frame: CGRect(x: 2300, y: 500, width: 89, height: 533), windowNumber: 793
        )
        let panelID = try #require(panel.identity)
        sensing.additionalWindows[panel.windowNumber] = panel
        context.reader.roles[panel.windowNumber] = .interactivePanel
        await context.seat.ownWindowBornInSeat(panel, level: 3)
        context.reader.recency = [RecencyClaim(
            surface: panelID, signal: .returnedToFront,
            provenance: .qualifiedFrontOrderAttestation,
            origin: .application(provenance: .qualifiedRaiseAttribution),
            observedAtNanoseconds: 100
        )]
        context.seat.refreshTargetReadings()
        context.seat.refreshTargetReadings()
        let windows = Windows()
        let menu = CGRect(x: 2300, y: 600, width: 200, height: 200)
        windows.rows = [
            WindowRow(layer: 101, frame: menu, number: 794),
            WindowRow(layer: 3, frame: panel.frame, number: panel.windowNumber),
            WindowRow(layer: 0, frame: context.window.reference.frame, title: "Edit", number: context.window.id)
        ]
        var displayReads = 0
        let provider = SeatSceneProvider(
            target: target, pipeline: ScenePipeline(text: EmptyText(), augmentation: CaptureAugmentation()),
            windows: windows, identity: { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") },
            freshStill: { _ in throw SeatDrivingFailure.frameUnusable },
            displayBounds: { _ in FakeGeometry.virtual },
            displayStill: { _ in
                displayReads += 1
                #expect(context.seat.currentTarget?.id == context.window.id)
                #expect(target.lastCapturedWindow?.id == panel.windowNumber)
                if superseded { _ = try await observe(context.seat) }
                return try #require(makeControlledFrame(of: panelID, screenRect: FakeGeometry.virtual))
            }
        )
        if superseded {
            await #expect(throws: SeatDrivingFailure.frameUnusable) {
                try await provider.currentScene(of: panel.processID)
            }
        } else {
            let scene = try await provider.currentScene(of: panel.processID)
            #expect(scene.frame == panel.frame.union(menu))
            #expect(scene.scene.elements.first?.value == "\(panel.processID):\(panel.windowNumber)")
        }
        #expect(displayReads == 1)
    }

    @Test("a dropdown result names the captured window from the current census")
    func dropdownUsesCapturedTitle() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let windows = Windows()
        windows.rows = [WindowRow(
            layer: 0, frame: context.window.reference.frame,
            title: "Renamed dialog", number: context.window.id
        )]
        let selector = SeatDropdownSelector(
            target: context.target, pipeline: ScenePipeline(text: EmptyText()), windows: windows
        )
        let result = try await selector.select(
            control: "Missing", item: "MP3",
            identity: ApplicationIdentity(bundleID: "com.test", name: "Test"), dryRun: true
        )
        #expect(result.outcome.scene?.windowTitle == "Renamed dialog")
    }

    @Test("a document change updates the title of the exact captured window")
    func documentTitleChanges() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let windows = Windows()
        let provider = SeatSceneProvider(
            target  : context.target,
            pipeline: ScenePipeline(text: EmptyText()),
            windows : windows,
            identity: { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") }
        )
        let number = context.window.id
        let frame = context.window.reference.frame
        windows.rows = [WindowRow(layer: 0, frame: frame, title: "Probe.png", number: number)]
        let original = try await provider.currentScene(of: context.window.reference.processID)
        #expect(original.scene.windowTitle == "Probe.png")

        windows.rows = [
            WindowRow(layer: 0, frame: frame, title: "Unrelated", number: number + 1),
            WindowRow(layer: 0, frame: frame, title: "Untitled-1", number: number)
        ]
        let changed = try await provider.currentScene(of: context.window.reference.processID)
        #expect(changed.scene.windowTitle == "Untitled-1")

        windows.rows = [WindowRow(layer: 0, frame: frame, title: "Probe.png", number: number + 1)]
        let missing = try await provider.currentScene(of: context.window.reference.processID)
        #expect(missing.scene.windowTitle.isEmpty)

        windows.rows = [
            WindowRow(layer: 0, frame: frame, title: "First", number: number),
            WindowRow(layer: 0, frame: frame, title: "Second", number: number)
        ]
        let ambiguous = try await provider.currentScene(of: context.window.reference.processID)
        #expect(ambiguous.scene.windowTitle.isEmpty)
    }

    // MARK: A scene answered again over the same pixels (ADR 0034)

    /// A recognizer that reads one new line on every run, so a scene the pipeline built again is
    /// never equal to the one before it, and a scene answered again without it always is.
    private final class CountingText: TextRecognizing, @unchecked Sendable {
        private let lock = NSLock()
        private var runs = 0
        var failsNext = false

        var count: Int { lock.withLock { runs } }

        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            let run = lock.withLock {
                runs += 1
                return runs
            }
            if lock.withLock({ failsNext }) {
                lock.withLock { failsNext = false }
                throw ObservationUnavailable.captureFailed(reason: "controlled recognizer failure")
            }
            return [RecognizedText(text: "Reading \(run)", pixelBox: CGRect(x: 20, y: 20, width: 120, height: 16))]
        }
    }

    private struct Reuse {
        let provider: SeatSceneProvider
        let text    : CountingText
        let source  : ControlledObservationSource
        let sensing : FakeSensing
        let seat    : AgentSeat
        let window  : AdoptedWindow
        let windows : Windows
        let target  : SeatTarget
    }

    private func reuse(
        marker    : Int64,
        augmentation: (any SceneAugmenting)? = nil,
        freshStill: @escaping @MainActor @Sendable (SeatTarget) async throws -> SeatFrame = { _ in
            throw ObservationUnavailable.captureFailed(reason: "no fresh still in this test")
        }
    ) async throws -> Reuse {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: marker)
        _ = try await observe(context.seat)
        let windows = Windows()
        windows.rows = [WindowRow(layer: 0, frame: context.window.reference.frame, title: "Doc", number: context.window.id)]
        let text = CountingText()
        let target = SeatTarget(borrowing: SeatHost(), seat: context.seat)
        let provider = SeatSceneProvider(
            target    : target,
            pipeline  : ScenePipeline(text: text, augmentation: augmentation),
            windows   : windows,
            identity  : { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") },
            freshStill: freshStill
        )
        return Reuse(
            provider: provider,
            text    : text,
            source  : context.source,
            sensing : sensing,
            seat    : context.seat,
            window  : context.window,
            windows : windows,
            target  : target
        )
    }

    @Test("the Seat reconciles selection before perception lists popup windows")
    func observationPrecedesWindowCensus() async throws {
        let context = try await reuse(marker: 968)
        context.source.duringCapture = {
            #expect(context.windows.reads == 0,
                    "a census before reconciliation can omit a newly adopted dialog")
        }
        let captures = context.source.requested.count
        _ = try await context.provider.currentScene(of: context.window.reference.processID)
        #expect(context.windows.reads >= 1)
        #expect(context.source.requested.count == captures + 1)
    }

    private actor ChangingAugmentation: SceneAugmenting {
        var reads = 0

        func augmentation(
            for processID: pid_t, windowNumber: Int, windowFrame: CGRect
        ) async throws -> AccessibilityHarvest {
            try await augmentation(for: processID, windowFrame: windowFrame)
        }

        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            reads += 1
            if reads == 4 {
                return AccessibilityHarvest(elements: [], quality: CaptureQuality(windowFound: false))
            }
            let element = SceneElement(
                id: "control|mute", kind: .control, label: "Mute",
                bounds: NormalizedRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05),
                role: "AXButton", state: reads == 2 ? .on : .off, container: "Kick"
            )
            return AccessibilityHarvest(
                elements: [element], quality: CaptureQuality(walkCompleted: true, windowFound: true)
            )
        }
    }

    @Test("identical pixels refresh native states and drop facts from an unavailable window",
          arguments: [false, true])
    func identicalPixelsRefreshNativeFacts(afterCommand: Bool) async throws {
        let augmentation = ChangingAugmentation()
        let stills = FreshStills()
        let context = try await reuse(
            marker: 971, augmentation: augmentation, freshStill: { _ in try stills.still() }
        )
        stills.window = context.window
        let processID = context.window.reference.processID
        var scenes: [PerceivedWindow] = []
        for _ in 0..<4 {
            scenes.append(try await context.provider.currentScene(of: processID))
            if afterCommand { context.target.spendObservation() }
        }
        #expect(scenes.map { $0.scene.elements.first { $0.container == "Kick" }?.state } == [.off, .on, .off, nil])
        #expect(scenes.last?.capture.windowFound == false)
        #expect(context.text.count == 1, "only pixel work is reused")
        #expect(await augmentation.reads == 4)
        #expect(scenes[0].scene.token != scenes[1].scene.token)
    }

    @Test("byte-identical pixels of the same window reuse pixel recognition")
    func samePixelsReuseTheScene() async throws {
        let context = try await reuse(marker: 960)
        let processID = context.window.reference.processID

        let first = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 1, "with no previous frame the pipeline runs")
        let captures = context.source.requested.count
        let second = try await context.provider.currentScene(of: processID)

        #expect(context.source.requested.count == captures + 1, "every scene still takes a fresh observation")
        #expect(context.text.count == 1, "the pipeline did not run again")
        #expect(second == first)
        // The baseline path of AutomationTools: an equal scene is its unchanged sentence.
        #expect(SceneChanges.text(from: first.scene, to: second.scene, since: 1) == "Unchanged since revision 1.")
    }

    @Test("a change of one pixel byte runs the pipeline and never answers unchanged")
    func changedPixelsRunThePipeline() async throws {
        let context = try await reuse(marker: 961)
        let processID = context.window.reference.processID
        let first = try await context.provider.currentScene(of: processID)

        context.source.paint = { buffer in
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            CVPixelBufferGetBaseAddress(buffer)?.storeBytes(of: UInt8(1), toByteOffset: 4 * 33 + 2, as: UInt8.self)
        }
        let changed = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
        #expect(SceneChanges.text(from: first.scene, to: changed.scene, since: 1) != "Unchanged since revision 1.")

        // The changed pixels are now the kept ones, and returning to the first pixels is a change too.
        let again = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
        #expect(again == changed)
        context.source.paint = nil
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 3)
    }

    @Test("the same pixels of another window, or under another title, run the pipeline")
    func otherWindowRunsThePipeline() async throws {
        let context = try await reuse(marker: 962)
        let processID = context.window.reference.processID
        _ = try await context.provider.currentScene(of: processID)

        context.windows.rows = [WindowRow(layer: 0, frame: context.window.reference.frame, title: "Other",
                                          number: context.window.id)]
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2, "the census title is part of what must match")

        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        context.sensing.additionalWindows[reference.windowNumber] = reference
        let other = try await context.seat.adopt(reference, platform: AppKitPlatform())
        #expect(context.seat.currentTarget?.id == other.id)
        context.windows.rows.append(WindowRow(layer: 0, frame: reference.frame, title: "Other", number: other.id))
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.source.requested.last == reference.identity)
        #expect(context.text.count == 3)
    }

    @Test("a scene that failed is never kept, so the next identical pixels run the pipeline")
    func failedSceneIsNotKept() async throws {
        let context = try await reuse(marker: 963)
        let processID = context.window.reference.processID
        context.text.failsNext = true
        await #expect(throws: (any Error).self) { try await context.provider.currentScene(of: processID) }
        #expect(context.text.count == 1)

        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
    }

    // MARK: A kept scene after a Command

    /// Answers the fresh still a kept scene is confirmed against: a frame of `window` displayed now,
    /// painted with `value` in its first byte, and counts how often it was asked.
    @MainActor
    private final class FreshStills {
        var asked = 0
        var value: UInt8 = 0
        var window: AdoptedWindow?

        func still() throws -> SeatFrame {
            asked += 1
            guard let identity = window?.reference.identity, let frame = makeControlledFrame(
                of         : identity,
                screenRect : window?.reference.frame ?? .zero,
                displayTime: mach_absolute_time()
            ) else { throw ObservationUnavailable.captureFailed(reason: "could not construct the fresh frame") }
            CVPixelBufferLockBaseAddress(frame.pixelBuffer, [])
            CVPixelBufferGetBaseAddress(frame.pixelBuffer)?.storeBytes(of: value, toByteOffset: 0, as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, [])
            return frame
        }
    }

    @Test("a kept frame displayed before the last Command is not reused; one displayed after it is")
    func reuseNeedsAFrameAfterTheCommand() {
        #expect(SeatSceneProvider.mayReuse(keptDisplayedAt: 1_000, lastCommandAt: nil))
        #expect(SeatSceneProvider.mayReuse(keptDisplayedAt: nil, lastCommandAt: nil))
        #expect(!SeatSceneProvider.mayReuse(keptDisplayedAt: 1_000, lastCommandAt: 2_000))
        #expect(!SeatSceneProvider.mayReuse(keptDisplayedAt: 2_000, lastCommandAt: 2_000))
        #expect(!SeatSceneProvider.mayReuse(keptDisplayedAt: nil, lastCommandAt: 2_000))
        #expect(SeatSceneProvider.mayReuse(keptDisplayedAt: 3_000, lastCommandAt: 2_000))
    }

    @Test("after a Command identical pixels are confirmed by a still started then, and a newer frame reuses")
    func identicalPixelsAfterACommandAreConfirmed() async throws {
        let stills = FreshStills()
        let context = try await reuse(marker: 964, freshStill: { _ in try stills.still() })
        stills.window = context.window
        let processID = context.window.reference.processID
        let first = try await context.provider.currentScene(of: processID)

        context.target.spendObservation()
        let confirmed = try await context.provider.currentScene(of: processID)
        #expect(stills.asked == 1, "the kept frame predates the Command, so a fresh still decides")
        #expect(context.text.count == 1, "the fresh still matched, so the pipeline did not run")
        #expect(confirmed == first)

        _ = try await context.provider.currentScene(of: processID)
        #expect(stills.asked == 1, "the kept frame is now the fresh one, displayed after the Command")
        #expect(context.text.count == 1)
    }

    @Test("after a Command a fresh still that differs runs the pipeline on its pixels")
    func freshStillThatDiffersIsRead() async throws {
        let stills = FreshStills()
        stills.value = 7
        let context = try await reuse(marker: 965, freshStill: { _ in try stills.still() })
        stills.window = context.window
        let processID = context.window.reference.processID
        _ = try await context.provider.currentScene(of: processID)

        context.target.spendObservation()
        _ = try await context.provider.currentScene(of: processID)
        #expect(stills.asked == 1)
        #expect(context.text.count == 2, "the stale running-stream pixels were not answered as unchanged")
        let image = try #require(context.target.lastSceneImage)
        let firstByte = image.dataProvider?.data.flatMap { CFDataGetBytePtr($0)?[0] }
        #expect(firstByte == 7, "the scene was read from the fresh still")
    }

    @Test("after a Command a fresh still that fails runs the pipeline instead of reusing")
    func freshStillFailureIsNotAReuse() async throws {
        let context = try await reuse(marker: 966)
        let processID = context.window.reference.processID
        _ = try await context.provider.currentScene(of: processID)

        context.target.spendObservation()
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
    }
}
