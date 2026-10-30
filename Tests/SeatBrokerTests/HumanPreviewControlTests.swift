//
//  HumanPreviewControlTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/10/2026.
//

import CoreGraphics
import CursorGuard
import Foundation
import InteractionListener
import PerceptionCore
import Testing
import SeatCore
import SeatDriving
import WindowPlacement
@testable import SeatSession
@testable import SeatInput
@testable import SeatBroker

@MainActor
@Suite("Human preview ownership")
struct HumanPreviewControlTests {

    @Test func bothLendingHooksShareOnePresentationBudget() async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        let control = session.makeHumanPreviewControl(suspend: {}, waitForAgent: {}, endAgent: {})
        var releaseAll: CheckedContinuation<Void, Never>?
        var releaseFront: CheckedContinuation<Void, Never>?
        control.willLendAll = { _ in await withCheckedContinuation { releaseAll = $0 } }
        control.willLend = { _ in await withCheckedContinuation { releaseFront = $0 } }
        let reference = WindowReference(processID: 42, windowNumber: 7,
                                        frame: CGRect(x: 20, y: 30, width: 800, height: 600))
        let started = ContinuousClock.now
        await control.prepareLend([reference], frontWindowNumber: 7)
        let elapsed = started.duration(to: .now)
        #expect(releaseAll != nil && releaseFront != nil)
        #expect(elapsed >= .milliseconds(2400))
        #expect(elapsed < .seconds(4))
        releaseAll?.resume()
        releaseFront?.resume()
    }

    @Test func takeBackHookIsCappedWhenItDoesNotReturn() async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        let control = session.makeHumanPreviewControl(suspend: {}, waitForAgent: {}, endAgent: {})
        var release: CheckedContinuation<Void, Never>?
        var returned = false
        control.willTakeBack = { _ in
            await withCheckedContinuation { release = $0 }
            returned = true
        }
        let started = ContinuousClock.now
        await control.prepareTakeBack([])
        let elapsed = started.duration(to: .now)
        #expect(!returned)
        #expect(elapsed >= .milliseconds(450))
        #expect(elapsed < .seconds(2))
        release?.resume()
    }
    @Test func allWindowHooksKeepLegacyAndPublishConfirmedLoans() async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        let source = PreviewEventSource()
        let control = HumanPreviewControl(session: session, suspend: {}, waitForAgent: {}, endAgent: {},
                                          interactionSource: { source }, sceneReader: nil)
        let process = ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2)
        let windows = [7, 8].map { number in
            WindowReference(identity: WindowIdentity(process: process, windowNumber: number, ownerConnectionID: 3),
                            frame: CGRect(x: number * 20, y: 40, width: 500, height: 300))
        }
        var all: [LentWindow] = []
        var front: LentWindow?
        control.willLendAll = { all = $0 }
        control.willLend = { front = $0 }
        await control.prepareLend(windows, frontWindowNumber: 7)
        #expect(all.map(\.frame) == windows.map(\.frame))
        #expect(front == all.first)
        var report = ApplicationLendingReport()
        report.moves = windows.map { .init(window: $0.identity!, before: .zero, after: $0.frame) }
        control.didLend(report)
        #expect(control.lentWindows == all)
        var takeBack: [LentWindow] = []
        control.willTakeBack = { takeBack = $0 }
        await control.prepareTakeBack(windows)
        #expect(takeBack == all)
        await control.finish()
        #expect(control.lentWindows.isEmpty)
    }

    @Test func endControlOverridesYesWhileTheOldWorkerDrains() async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        var release: CheckedContinuation<Void, Never>?
        var resumes = 0
        let control = HumanPreviewControl(
            session: session,
            suspend: {},
            waitForAgent: {},
            endAgent: {},
            waitForWorker: { await withCheckedContinuation { release = $0 } },
            resumeAgent: { _, _ in resumes += 1 },
            sceneReader: nil
        )
        let yes = Task { await control.finish(.resumingWorker) }
        while release == nil { await Task.yield() }
        let stop = Task { await control.finish(.closingSession) }
        for _ in 0..<10 { await Task.yield() }
        release?.resume()
        await yes.value
        await stop.value
        #expect(control.isFinished)
        #expect(resumes == 0)
    }

    @Test func repeatedYesAfterTakeBackFailureStillSchedulesOnlyOneResume() async throws {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        var resumes = 0
        var drains = 0
        var message = ""
        let control = HumanPreviewControl(
            session: session,
            suspend: {},
            waitForAgent: {},
            endAgent: { Issue.record("Yes must not stop the worker") },
            waitForWorker: { drains += 1 },
            resumeAgent: { summary, beginTurn in
                #expect(drains == 1)
                resumes += 1
                message = summary
                try await session.turn { try await beginTurn() }
            },
            sceneReader: nil
        )
        let first = Task { await control.finish(.resumingWorker) }
        let second = Task { await control.finish(.resumingWorker) }
        await first.value
        await second.value
        #expect(control.isFinished)
        #expect(resumes == 1)
        #expect(message.contains("Take-back failed"))
        #expect(message.contains("Recording is incomplete"))
    }

    /// No window is adopted: only the real Seat, gate, preview and broker lifetimes run.
    nonisolated private struct EmptySeatFacilities: SeatSensing, WindowPlacing, CommandSending {
        let gate = InputCommandGate()
        var inputCommandGate: InputCommandGate? { gate }
        let unvalidatedBuild = false
        let mainDisplayID: CGDirectDisplayID = 1
        let physicalTopologyIsUnchanged = true
        let physicalDisplayWasAdded = false
        let virtualDisplayIsOnline = true
        let virtualDisplayBounds = CGRect(x: 1000, y: 0, width: 500, height: 500)
        let fenceIsActive = true
        let cursorLocation: CGPoint? = .zero
        let frontmostProcessID: Int32? = nil
        var focusedUserWindow: WindowReference? { nil }
        var userMayBeSwitchingApplications: Bool { false }
        var desktopLayout: DesktopLayout? { nil }
        func fenceContainsPhysicalPoint(_ point: CGPoint) -> Bool { true }
        func drainFenceSignals() -> FenceSignals { .quiet }
        func windowGeometry(of windowNumber: Int) -> WindowReference? { nil }
        func windowGeometryReading(of windowNumber: Int) -> WindowServerProbe.GeometryReading { .refused }
        func windowGeometryObservation(of window: WindowReference) -> WindowGeometryObservation? { nil }
        func windowIsVisibleOnPhysicalDisplay(_ window: WindowReference) -> Bool { false }
        func visibleWindowsAreVirtual(ownedBy processID: Int32) -> Bool { false }
        func windowOrder(of windowNumber: Int,
                         behindFrontmostWindowOf processID: Int32?) -> (orderIndex: Int?, isBehind: Bool?) { (nil, nil) }
        func windowSurfaces(ownedBy processIDs: Set<Int32>) -> [WindowSurface]? { nil }
        func windowSurfaces(inFrontOf surface: WindowIdentity) -> [WindowSurface]? { nil }
        func windowIsOrderedOut(_ window: WindowReference) -> Bool { false }
        func windowIsDestroyed(_ window: WindowReference) -> Bool { false }
        func windowSpaces(of windowNumber: Int) -> [Int]? { nil }
        func isActive(processID: Int32) -> Bool? { false }
        func isBehindFrontmostWindow(windowNumber: Int, ownedBy processID: Int32) -> Bool? { nil }
        func windowOrderIndex(of windowNumber: Int) -> Int? { nil }
        func menuWindows(ownedBy processID: Int32) -> [WindowReference] { [] }
        func move(_ window: WindowReference, to origin: CGPoint) throws { throw CancellationError() }
        func resize(_ window: WindowReference, to size: CGSize) throws { throw CancellationError() }
        func frame(of window: WindowReference) throws -> CGRect? { nil }
        func stage(_ window: WindowReference, expectedSize: CGSize,
                   within bounds: CGRect) async throws -> WindowReference { throw CancellationError() }
        func recover(_ window: WindowReference, expectedTitle: String, expectedSize: CGSize,
                     sourceDisplayBounds: CGRect, to origin: CGPoint) throws { throw CancellationError() }
        func send(_ command: InputCommand, to window: WindowReference, correlationID: Int64,
                  platform: any InputPlatform) async throws -> InputReceipt { throw CancellationError() }
        func sendSequence(_ commands: [InputCommand], to window: WindowReference, correlationID: Int64,
                          platform: any InputPlatform) async throws -> [InputReceipt] { throw CancellationError() }
        func cyclePreparation(on window: WindowReference) async throws { throw CancellationError() }
    }

    @Test func lendingRefusalDoesNotBlockControl() {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        let control = session.makeHumanPreviewControl(suspend: {}, waitForAgent: {}, endAgent: {})
        control.lendingWasRefused(.noWindows)
        #expect(!control.isBlocked)
        #expect(control.lentWindow == nil)
        #expect(control.status.contains("Nothing was moved"))
        control.lendingWasRefused(.inventoryUnavailable)
        #expect(!control.isBlocked)
        #expect(control.status.contains("inventory"))
    }

    @Test(arguments: ["finish", "close", "block", "stream failure"])
    func unverifiedActivationKeepsHumanControlAndItsReport(ending: String) async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory)
        let source = PreviewEventSource()
        let control = HumanPreviewControl(session: session, suspend: {}, waitForAgent: {}, endAgent: {},
                                          interactionSource: { source }, sceneReader: nil)
        let identity = WindowIdentity(
            process: ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2),
            windowNumber: 7, ownerConnectionID: 3)
        var report = ApplicationLendingReport()
        report.personHasControl = true
        report.activation = .unverified
        report.activationWindow = identity
        report.activationAttempts = 2
        report.moves = [.init(window: identity, before: .zero, after: CGRect(x: 10, y: 20, width: 800, height: 600))]
        report.failures = [.init(windowNumber: 7, reason: "The window stayed stashed.")]
        control.didLend(report)
        #expect(!control.isBlocked)
        #expect(control.lentWindow?.windowNumber == 7)
        #expect(control.status.contains("still have control"))
        #expect(control.status.contains("stayed stashed"))
        if ending == "close" {
            control.sessionWillClose()
            await control.drainForSessionClose()
            control.sessionDidClose()
        } else {
            if ending == "block" { control.block(CancellationError()) }
            if ending == "stream failure" { source.continuation.finish(throwing: CancellationError()) }
            if ending == "block" || ending == "stream failure" {
                let deadline = ContinuousClock.now + .seconds(2)
                while !source.stopped, ContinuousClock.now < deadline { await Task.yield() }
                #expect(control.isBlocked)
                #expect(source.stopped)
            }
            await control.finish()
        }
        #expect(source.stopped)
        #expect(control.isFinished)
        #expect(control.history.isEmpty)
    }

    @Test("End Control and broker closure abandon normal and blocked human episodes",
          arguments: [false, true], [false, true])
    func controlClosureClearsEpisode(closeSession: Bool, drainFails: Bool) async throws {
        let facilities = EmptySeatFacilities()
        let seat = AgentSeat(sensing: facilities, placing: facilities, sender: facilities,
            fence: nil, displayID: 2, expectedMainDisplayID: 1)
        let target = SeatTarget(borrowing: SeatHost(), seat: seat)
        let broker = SeatBroker()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = SceneSnapshot(bundleID: "test.human", appName: "Test", windowTitle: "Test",
            viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let session = BrokeredAutomationSession(broker: broker, workerID: UUID(),
            knowledgeDirectory: scratch, allowsDestructive: false,
            missingGrant: { nil }, requestGrants: {}, seating: { _, _, _ in
                (TargetApp(pid: getpid(), bundleID: "test.human", name: "Test", bundleURL: nil, windows: []), target)
            }, perceiving: { _, _ in scene })
        _ = try await session.open(application: "test.human", window: nil)
        var suspensions = 0
        var drains = 0
        var stops = 0
        let control = session.makeHumanPreviewControl(
            suspend: {
                #expect(facilities.gate.pauseReasons == [.humanIntervention])
                suspensions += 1
            }, waitForAgent: {
                drains += 1
                if drainFails { throw CancellationError() }
            }, endAgent: { stops += 1 })
        try control.begin()
        try control.begin()
        #expect(suspensions == 1)
        #expect(control.history.isEmpty)
        #expect(control.eventCount == 0)
        #expect(facilities.gate.hasHumanInput)
        let deadline = ContinuousClock.now + .seconds(2)
        while drains == 0 || drainFails && !control.isBlocked, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(drains == 1)
        #expect(control.isBlocked == drainFails)
        if closeSession { await session.close() } else { await control.finish() }
        #expect(control.isFinished)
        #expect(!seat.hasHumanInput)
        #expect(!facilities.gate.hasHumanInput)
        #expect(drains == 1)
        #expect(stops == (closeSession ? 0 : 1))
        try facilities.gate.check()
        await session.close()
        await broker.queue.shutdown()
    }

    @Test func openingAndFinishingAnUnusedPreviewDoNotSuspendOrStopAnAgent() async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory
        )
        var suspensions = 0
        var drains = 0
        var stops = 0
        let control = session.makeHumanPreviewControl(
            suspend: { suspensions += 1 }, waitForAgent: { drains += 1 }, endAgent: { stops += 1 }
        )
        #expect(!control.hasStarted)
        #expect(suspensions == 0)
        await control.finish()
        await control.finish()
        #expect(control.isFinished)
        #expect(!control.isFinishing)
        #expect(drains == 0)
        #expect(stops == 0)
    }

    @Test func aRetainedPictureIsScaledDownToFit1080pAndNeverUp() throws {
        func image(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
            return try #require(context.makeImage())
        }
        let bounds = HumanPreviewControl.retainedPictureBounds
        let display = try #require(HumanPreviewControl.scaledToFit(try image(2560, 1440), bounds))
        #expect((display.width, display.height) == (1920, 1080))
        let window = try #require(HumanPreviewControl.scaledToFit(try image(1261, 827), bounds))
        #expect((window.width, window.height) == (1261, 827))

    }

    @Test func sessionClosureReleasesEverySuspendedRecorderWaiter() async {
        let session = BrokeredAutomationSession(
            broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: FileManager.default.temporaryDirectory
        )
        let control = session.makeHumanPreviewControl(suspend: {}, waitForAgent: {}, endAgent: {})
        var ended = 0
        let first = Task { await control.waitUntilFinished(); ended += 1 }
        let second = Task { await control.waitUntilFinished(); ended += 1 }
        await Task.yield()
        #expect(ended == 0)
        control.sessionWillClose()
        await control.drainForSessionClose()
        control.sessionDidClose()
        await first.value
        await second.value
        #expect(ended == 2)
        await control.waitUntilFinished()
    }

    @Test("End Control while the session closes skips take-back; the later resume path keeps it")
    func endPathChoosesTakeBack() {
        #expect(!HumanControlEnd.closingSession.takesBackApplication)
        #expect(HumanControlEnd.resumingWorker.takesBackApplication)
    }

    @Test("The lent front window is the target's move, the first move without it, nothing without moves")
    func lentFrontWindow() {
        let process = ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2)
        func move(_ number: Int, _ frame: CGRect) -> ApplicationLendingReport.Move {
            .init(window: WindowIdentity(process: process, windowNumber: number, ownerConnectionID: 3),
                  before: .zero, after: frame)
        }
        var report = ApplicationLendingReport()
        #expect(LentWindow.front(of: report, target: 7) == nil)
        report.moves = [move(5, CGRect(x: 1, y: 2, width: 3, height: 4)),
                        move(7, CGRect(x: 100, y: -118, width: 800, height: 600))]
        #expect(LentWindow.front(of: report, target: 7)
            == LentWindow(windowNumber: 7, processID: 42, frame: CGRect(x: 100, y: -118, width: 800, height: 600)))
        #expect(LentWindow.front(of: report, target: 9)?.windowNumber == 5)
        #expect(LentWindow.front(of: report, target: nil)?.windowNumber == 5)
    }
}

@MainActor
private final class PreviewEventSource: HumanInteractionSource {
    let buttons = InteractionButtonState()
    let events: AsyncThrowingStream<InteractionEvent, any Error>
    let continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation
    var stopped = false

    init() { (events, continuation) = AsyncThrowingStream.makeStream() }

    func stop() async {
        stopped = true
        continuation.finish()
    }
}
