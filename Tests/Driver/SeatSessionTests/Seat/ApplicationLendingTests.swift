//
//  ApplicationLendingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import SeatDriving
@testable import SeatSession
import Testing
import VirtualScreens

@MainActor
@Suite("Application lending")
struct ApplicationLendingTests {
    @Test(arguments: [false, true])
    func independentDestinationsKeepFallbackAndReportFinalFrames(clamped: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, windows) = try await MultiWindowTests.seat(sensing: sensing, placing: placing, also: [778])
        let visible = FakeGeometry.physical
        let anchor = CGRect(x: 200, y: 150, width: 700, height: 500)
        let frames = windows.map(\.reference.frame)
        let front = try #require(frames.indices.max {
            frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height
        })
        let fallback = ApplicationLendingLayout(
            frames: frames,
            visibleFrame: visible,
            anchor: (front, CGPoint(x: anchor.midX, y: anchor.midY))
        )
        let destination = CGRect(
            x: clamped ? visible.maxX + 200 : visible.minX + 20,
            y: clamped ? visible.minY - 200 : visible.minY + 30,
            width: 1,
            height: 1
        )
        let expected = CGRect(
            x: clamped ? max(visible.minX, visible.maxX - frames[1].width) : destination.minX,
            y: clamped ? visible.minY : destination.minY,
            width: frames[1].width,
            height: frames[1].height
        )
        var moves = 0
        placing.onWindowMove = { window, origin in
            moves += 1
            let moved = window.replacingFrame(CGRect(origin: origin, size: window.frame.size))
            placing.bodyFrames[window.windowNumber] = moved.frame
            if window.windowNumber == windows[0].id { sensing.geometry = moved }
            else { sensing.additionalWindows[window.windowNumber] = moved }
        }
        _ = try seat.beginHumanInput()
        var planned: [WindowReference] = []
        let report = try await seat.lendApplication(
            visibleFrame: visible,
            around: anchor,
            lendingFrames: [778: destination, 999: .zero],
            willMoveAll: { windows in
                #expect(moves == 0)
                planned = windows
            }
        ) { _ in }
        #expect(report.failures.isEmpty)
        #expect(planned.first { $0.windowNumber == 778 }?.frame == expected)
        #expect(planned.first { $0.windowNumber == windows[0].id }?.frame == fallback.frames[0])
        #expect(report.moves.map(\.after) == planned.map(\.frame))
        #expect(report.wasClamped == clamped)
    }

    @Test func independentLayoutPreservesSizesAndLegacyFallback() {
        let frames = [
            CGRect(x: 2000, y: 100, width: 600, height: 400),
            CGRect(x: 2200, y: 250, width: 200, height: 150),
            CGRect(x: 2600, y: 300, width: 100, height: 80)
        ]
        let visible = CGRect(x: -1200, y: 30, width: 1200, height: 800)
        let anchor = (front: 0, center: CGPoint(x: -700, y: 400))
        let fallback = ApplicationLendingLayout(frames: frames, visibleFrame: visible, anchor: anchor)
        let layout = ApplicationLendingLayout(
            frames: frames,
            visibleFrame: visible,
            anchor: anchor,
            destinations: [CGRect(x: -1100, y: 80, width: 1, height: 1), nil,
                           CGRect(x: 500, y: -500, width: 1, height: 1)]
        )
        #expect(layout.frames[0] == CGRect(x: -1100, y: 80, width: 600, height: 400))
        #expect(layout.frames[1] == fallback.frames[1])
        #expect(layout.frames[2] == CGRect(x: -100, y: 30, width: 100, height: 80))
        #expect(layout.wasClamped)
        let empty = ApplicationLendingLayout(frames: frames, visibleFrame: visible, anchor: anchor, destinations: [])
        #expect(empty.frames == fallback.frames)
        #expect(empty.wasClamped == fallback.wasClamped)
        let invalid = ApplicationLendingLayout(
            frames: frames,
            visibleFrame: visible,
            anchor: anchor,
            destinations: [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)]
        )
        #expect(invalid.frames == fallback.frames)
        #expect(invalid.wasClamped == fallback.wasClamped)
    }

    @Test func independentLayoutDoesNotReportUnusedGroupClamping() {
        let frames = [
            CGRect(x: 2000, y: 100, width: 200, height: 100),
            CGRect(x: 4000, y: 100, width: 200, height: 100)
        ]
        let destinations = [
            CGRect(x: 50, y: 50, width: 200, height: 100),
            CGRect(x: 600, y: 400, width: 200, height: 100)
        ]
        let layout = ApplicationLendingLayout(
            frames: frames,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            destinations: destinations
        )
        #expect(layout.frames == destinations)
        #expect(!layout.wasClamped)
    }

    @Test func independentLayoutPinsOversizedWindowsWithoutResizing() {
        let frame = CGRect(x: 2000, y: 100, width: 1600, height: 1000)
        let visible = CGRect(x: 10, y: 40, width: 1200, height: 800)
        let layout = ApplicationLendingLayout(
            frames: [frame],
            visibleFrame: visible,
            destinations: [CGRect(x: 300, y: 200, width: 100, height: 100)]
        )
        #expect(layout.frames == [CGRect(origin: visible.origin, size: frame.size)])
        #expect(layout.wasClamped)
    }

    @Test func allPlannedAndCurrentFramesArriveBeforeAnyMove() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, windows) = try await MultiWindowTests.seat(sensing: sensing, placing: placing, also: [778])
        var moves = 0
        placing.onWindowMove = { window, origin in
            moves += 1
            let moved = window.replacingFrame(CGRect(origin: origin, size: window.frame.size))
            placing.bodyFrames[window.windowNumber] = moved.frame
            if window.windowNumber == windows[0].id { sensing.geometry = moved }
            else { sensing.additionalWindows[window.windowNumber] = moved }
        }
        _ = try seat.beginHumanInput()
        var planned: [WindowReference] = []
        var legacy: CGRect?
        let lent = try await seat.lendApplication(
            visibleFrame: FakeGeometry.physical,
            willMove: { _, frame in
                #expect(moves == 0)
                legacy = frame
            },
            willMoveAll: { frames in
                #expect(moves == 0)
                planned = frames
            }
        ) { _ in }
        #expect(lent.failures.isEmpty)
        #expect(planned.count == 2)
        #expect(planned.map(\.frame) == lent.moves.map(\.after))
        #expect(planned.contains { $0.frame == legacy })
        let movedByPerson = CGRect(x: 100, y: 150, width: 600, height: 400)
        sensing.additionalWindows[778] = windows[1].reference.replacingFrame(movedByPerson)
        placing.bodyFrames[778] = movedByPerson
        let beforeTakeBack = moves
        var current: [WindowReference] = []
        _ = try await seat.takeBackApplication(willMoveAll: { frames in
            #expect(moves == beforeTakeBack)
            current = frames
        })
        #expect(current.count == 2)
        #expect(current.first { $0.windowNumber == 778 }?.frame == movedByPerson)
    }

    @Test func interruptedObservationCanLendAndTakeBack() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let source = ControlledObservationSource(sensing: sensing)
        let seat = makeSeat(sensing: sensing, placing: placing, source: source, clock: ControlledContentClock())
        let adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let target = SeatTarget(borrowing: SeatHost(), seat: seat)
        var capturing = false
        source.duringCapture = {
            capturing = true
            try? await Task.sleep(for: .seconds(10))
        }
        source.permanentFailure = CancellationError()
        let read = Task { try await target.observe() }
        #expect(await AppWindowFollowTests.settle({ capturing }, within: 2))
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(seat.adoptedWindows.map(\.id) == [adopted.id])
        #expect(!seat.isApplicationLent)
        source.duringCapture = nil
        source.permanentFailure = nil
        placing.onMove = { origin in
            sensing.geometry = sensing.geometry?.replacingFrame(CGRect(origin: origin, size: adopted.reference.frame.size))
        }
        let token = try seat.beginHumanInput()
        let lent = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        #expect(lent.failures.isEmpty)
        #expect(seat.isApplicationLent)
        sensing.surfaces = [WindowSurface(reference: try #require(sensing.geometry), level: 0, isVisible: true)]
        let back = try await seat.takeBackApplication()
        #expect(back.failures.isEmpty)
        try await seat.endHumanInput(token)
    }

    @Test(arguments: [false, true])
    func changedTargetRefreshesRemainingWindows(identityChanged: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, windows) = try await MultiWindowTests.seat(sensing: sensing, placing: placing, also: [778])
        let survivor = windows[0].reference
        sensing.additionalWindows[778] = identityChanged
            ? FakeGeometry.reference(frame: windows[1].reference.frame, windowNumber: 778, lifetime: 2) : nil
        sensing.surfaces = [WindowSurface(reference: survivor, level: 0, isVisible: true)]
        placing.onWindowMove = { window, origin in
            #expect(window.identity == survivor.identity)
            sensing.geometry = window.replacingFrame(CGRect(origin: origin, size: window.frame.size))
        }
        _ = try seat.beginHumanInput()
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { window in
            #expect(window.identity == survivor.identity)
        }
        #expect(report.failures.isEmpty)
        #expect(report.moves.map(\.window) == [survivor.identity])
        #expect(seat.isApplicationLent)
    }

    @Test(arguments: [false, true])
    func thumbnailActivationIsRetried(staysStashed: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            let frame = CGRect(origin: origin, size: window.reference.frame.size)
            placing.bodyFrame = frame
            sensing.geometry = window.reference.replacingFrame(frame)
        }
        _ = try seat.beginHumanInput()
        var activations = 0
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { target in
            activations += 1
            sensing.geometry = target.replacingFrame(activations == 1 || staysStashed
                ? CGRect(x: 10, y: 100, width: 100, height: 80) : try #require(placing.bodyFrame))
        }
        #expect(activations == 2)
        #expect(report.activationAttempts == 2)
        #expect(report.activation == (staysStashed ? .unverified : .verified))
        #expect(report.personHasControl)
        #expect(staysStashed ? sensing.lendingOrderReads == 0 : sensing.lendingOrderReads >= 2)
        #expect(report.failures.isEmpty == !staysStashed)
        #expect(seat.isApplicationLent)
        #expect(seat.inputPauseReasons.contains(.humanIntervention))
    }

    @Test(arguments: [false, true])
    func refreshedInventoryRefusesWithoutMoving(inventoryFails: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        sensing.geometry = nil
        sensing.surfaces = inventoryFails ? nil : []
        _ = try seat.beginHumanInput()
        let moves = placing.moves.count
        do {
            _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in
                Issue.record("A refused loan must not activate")
            }
            Issue.record("An empty or unavailable inventory must refuse")
        } catch {
            #expect(error.localizedDescription.contains(inventoryFails ? "inventory" : "No windows"))
        }
        #expect(placing.moves.count == moves)
        #expect(!seat.isApplicationLent)
    }

    @Test func activatesLargestLentWindowInsteadOfSmallCurrentTarget() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, windows) = try await MultiWindowTests.seat(sensing: sensing, placing: placing, also: [778])
        sensing.additionalWindows[778] = windows[1].reference.replacingFrame(
            CGRect(x: 1800, y: 100, width: 66, height: 20))
        placing.bodyFrames[778] = sensing.additionalWindows[778]?.frame
        placing.onWindowMove = { window, origin in
            let moved = window.replacingFrame(CGRect(origin: origin, size: window.frame.size))
            placing.bodyFrames[window.windowNumber] = moved.frame
            if window.windowNumber == windows[0].id { sensing.geometry = moved }
            else { sensing.additionalWindows[window.windowNumber] = moved }
        }
        _ = try seat.beginHumanInput()
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { window in
            #expect(window.identity == windows[0].reference.identity)
        }
        #expect(report.moves.count == 2)
        #expect(report.failures.isEmpty)
    }

    @Test func identityChangeDuringPlacementNeverMovesTheReplacement() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let (seat, windows) = try await MultiWindowTests.seat(sensing: sensing, placing: placing, also: [778])
        var moved: [Int] = []
        placing.onWindowMove = { window, origin in
            moved.append(window.windowNumber)
            if window.windowNumber == windows[0].id {
                sensing.geometry = window.replacingFrame(CGRect(origin: origin, size: window.frame.size))
                sensing.additionalWindows[778] = FakeGeometry.reference(
                    frame: windows[1].reference.frame, windowNumber: 778, lifetime: 2)
            }
        }
        _ = try seat.beginHumanInput()
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        #expect(moved == [windows[0].id])
        #expect(report.failures.contains { $0.windowNumber == 778 })
    }

    @Test(arguments: [false, true])
    func fullSizeWithoutFrontmostProofIsReported(orderUnavailable: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        sensing.lendingWindowIsFrontmost = orderUnavailable ? nil : false
        _ = try seat.beginHumanInput()
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        #expect(report.activationAttempts == 2)
        #expect(report.activation == .unverified)
        #expect(!report.failures.isEmpty)
        #expect(report.personHasControl)
        #expect(sensing.lendingOrderReads > 0)
    }

    @Test func failedRefreshNeverMovesAnUnverifiedSurvivor() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        sensing.geometry = nil
        sensing.surfaces = [WindowSurface(reference: window.reference, level: 0, isVisible: true)]
        _ = try seat.beginHumanInput()
        let reads = sensing.surfaceReadCount
        let moves = placing.moves.count
        await #expect(throws: ApplicationLendingRefusal.self) {
            try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        }
        #expect(sensing.surfaceReadCount == reads + 1)
        #expect(placing.moves.count == moves)
        #expect(!seat.isApplicationLent)
    }

    @Test func activationChecksTheWholeDestinationScreen() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        _ = try seat.beginHumanInput()
        let visible = CGRect(x: 0, y: 30, width: 1512, height: 900)
        let report = try await seat.lendApplication(
            visibleFrame: visible, screenFrame: FakeGeometry.physical
        ) { _ in }
        #expect(report.activation == .verified)
        #expect(report.activationAttempts == 1)
        #expect(sensing.lendingOrderScreen == FakeGeometry.physical)
        #expect(report.moves.first?.after.midY == visible.midY)
    }

    @Test func groupLayout() {
        let frames = [CGRect(x: 1600, y: 100, width: 500, height: 400),
                      CGRect(x: 1800, y: 200, width: 300, height: 200)]
        // The person's external display is at (1512, 317, 1920, 1080) in WindowServer space.
        let visible = CGRect(x: 1512, y: 341, width: 1920, height: 1056)
        let layout = ApplicationLendingLayout(frames: frames, visibleFrame: visible)
        #expect(!layout.wasClamped)
        #expect(layout.frames[1].minX - layout.frames[0].minX == 200)
        #expect(layout.frames[1].minY - layout.frames[0].minY == 100)
        #expect(layout.frames[0].midX == visible.midX)
        #expect(layout.frames[0].midY == visible.midY)
        #expect(layout.frames.map(\.size) == frames.map(\.size))
    }

    @Test func anchoredGroupCentersItsFrontWindowOnTheAnchorInsideTheScreen() {
        let frames = [CGRect(x: 1600, y: 100, width: 500, height: 400),
                      CGRect(x: 1800, y: 200, width: 300, height: 200)]
        let visible = CGRect(x: 1512, y: 341, width: 1920, height: 1056)
        let layout = ApplicationLendingLayout(frames: frames, visibleFrame: visible, anchor: (0, CGPoint(x: 2400, y: 800)))
        #expect(layout.frames[0].midX == 2400)
        #expect(layout.frames[0].midY == 800)
        #expect(layout.frames[1].minX - layout.frames[0].minX == 200)
        // An anchor near the edge keeps the whole group on the screen.
        let edge = ApplicationLendingLayout(frames: frames, visibleFrame: visible, anchor: (0, CGPoint(x: 3400, y: 360)))
        #expect(edge.frames.reduce(CGRect.null) { $0.union($1) }.maxX == visible.maxX)
        #expect(edge.frames[0].minY == visible.minY)
    }

    @Test func oversizedGroupMovesWithoutResizing() {
        let frame = CGRect(x: 1700, y: 20, width: 1800, height: 1200)
        let visible = CGRect(x: 0, y: 30, width: 1200, height: 800)
        let layout = ApplicationLendingLayout(frames: [frame], visibleFrame: visible)
        #expect(layout.wasClamped)
        #expect(layout.frames == [CGRect(origin: visible.origin, size: frame.size)])
    }

    @Test func lendingAndTakeBack() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let before = adopted.reference.frame
        placing.onMove = { origin in
            sensing.geometry = sensing.geometry?.replacingFrame(CGRect(origin: origin, size: before.size))
        }
        let token = try seat.beginHumanInput()
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        #expect(report.failures.isEmpty)
        #expect(seat.isApplicationLent)
        #expect(seat.inputPauseReasons.contains(.humanIntervention))
        #expect(seat.isLent(adopted.reference))
        let record = try #require(seat.session[adopted.id])
        #expect(seat.currentIssues(for: record).isEmpty)
        sensing.fenceIsActive = false
        #expect(seat.currentIssues(for: record).contains(.fenceUnavailable))
        sensing.fenceIsActive = true
        #expect(!seat.isLent(FakeGeometry.reference(frame: before, processID: 9999, windowNumber: 55)))
        sensing.surfaces = [WindowSurface(reference: try #require(sensing.geometry), level: 0, isVisible: true)]
        let back = try await seat.takeBackApplication()
        #expect(back.failures.isEmpty)
        #expect(sensing.geometry?.frame == before)
        #expect(!seat.isApplicationLent)
        try await seat.endHumanInput(token)
        #expect(seat.inputPauseReasons.isEmpty)
    }

    @Test func takeBackKeepsThePersonsSize() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let before = adopted.reference.frame
        placing.onMove = { origin in
            sensing.geometry = sensing.geometry.map { $0.replacingFrame(CGRect(origin: origin, size: $0.frame.size)) }
        }
        let token = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        // The person shrinks the window while it is lent.
        let lent = try #require(sensing.geometry?.frame)
        let smaller = CGSize(width: before.width - 40, height: before.height - 30)
        sensing.geometry = sensing.geometry?.replacingFrame(CGRect(origin: lent.origin, size: smaller))
        placing.bodyFrame = CGRect(origin: lent.origin, size: smaller)
        sensing.surfaces = [WindowSurface(reference: try #require(sensing.geometry), level: 0, isVisible: true)]
        let back = try await seat.takeBackApplication()
        #expect(back.failures.isEmpty)
        #expect(placing.resizes.isEmpty)
        #expect(sensing.geometry?.frame == CGRect(origin: before.origin, size: smaller))
        // Releasing the window later returns it at the person's size too.
        #expect(seat.session[adopted.id]?.window.originalFrame.size == smaller)
        try await seat.endHumanInput(token)
    }

    @Test(arguments: [false, true]) func leaseEndLeavesLentWindowsAlone(unreadable: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = sensing.geometry?.replacingFrame(CGRect(origin: origin, size: FakeGeometry.adoptedWindow.frame.size))
        }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        let frame = sensing.geometry?.frame
        let moves = placing.moves.count
        if unreadable { placing.frameError = CancellationError() }
        await seat.abandonHumanInput(reason: .leaseEnded)
        #expect(!seat.isApplicationLent)
        #expect(!seat.hasHumanInput)
        #expect(seat.adoptedWindows.isEmpty)
        #expect(sensing.geometry?.frame == frame)
        #expect(placing.moves.count == moves)
    }

    @Test(arguments: [false, true]) func leaseEndRetainsStillVirtualWindows(moveFailed: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        if moveFailed { placing.moveError = CancellationError() }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        // Either the move never happened, or the application subsequently returned itself.
        sensing.geometry = window.reference
        placing.bodyFrame = moveFailed ? nil : window.reference.frame
        let moves = placing.moves.count
        await seat.abandonHumanInput(reason: .leaseEnded)
        #expect(!seat.isApplicationLent)
        #expect(!seat.hasHumanInput)
        #expect(seat.adoptedWindows.map(\.id) == [window.id])
        #expect(placing.moves.count == moves)
    }

    @Test func failedTakeBackRearmsGuards() async throws {
        enum Refusal: Error { case move }
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let adopted = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = sensing.geometry?.replacingFrame(CGRect(origin: origin, size: adopted.reference.frame.size))
        }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        sensing.surfaces = []
        placing.moveError = Refusal.move
        sensing.targetIsActive = true
        sensing.frontmostProcessID = adopted.reference.processID
        let report = try await seat.takeBackApplication()
        #expect(report.failures.map(\.windowNumber) == [adopted.id])
        #expect(!seat.isApplicationLent)
        #expect(!seat.isLent(adopted.reference))
        #expect(seat.currentIssues(for: try #require(seat.session[adopted.id])).contains(.targetActivated))
        #expect(seat.inputPauseReasons.contains(.humanIntervention))
    }
    @Test func dialogStaysWithPersonUntilTakeBack() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let fixture = try await AppWindowFollowTests.followingSeat(sensing: sensing, placing: placing)
        let seat = fixture.seat
        placing.onWindowMove = { window, origin in
            let frame = CGRect(origin: origin, size: window.frame.size)
            let moved = window.replacingFrame(frame)
            placing.bodyFrames[window.windowNumber] = frame
            if window.windowNumber == fixture.adopted.id { sensing.geometry = moved }
            else { sensing.additionalWindows[window.windowNumber] = moved }
            sensing.surfaces = (sensing.surfaces ?? []).map {
                $0.reference.windowNumber == window.windowNumber
                    ? WindowSurface(reference: moved, level: $0.level, isVisible: $0.isVisible) : $0
            }
        }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        let dialog = AppWindowFollowTests.reference(211, frame: CGRect(x: 300, y: 200, width: 400, height: 250))
        sensing.additionalWindows[211] = dialog
        placing.bodyFrames[211] = dialog.frame
        sensing.surfaces?.append(AppWindowFollowTests.surface(dialog, level: 3))
        let menu = AppWindowFollowTests.reference(212)
        sensing.surfaces?.append(AppWindowFollowTests.surface(menu, level: 1000))
        let count = placing.moves.count
        await seat.runWindowFollowPass()
        await seat.runWindowFollowPass()
        #expect(placing.moves.count == count)
        #expect(!seat.adoptedWindows.contains { $0.id == 211 })
        #expect(seat.isLent(dialog))
        var offered: [WindowReference] = []
        let report = try await seat.takeBackApplication(willMoveAll: { windows in
            #expect(placing.moves.count == count)
            offered = windows
        })
        #expect(offered.first { $0.windowNumber == 211 }?.frame == dialog.frame)
        #expect(!offered.contains { $0.windowNumber == 212 })
        #expect(report.failures.isEmpty)
        #expect(seat.adoptedWindows.contains { $0.id == 211 })
        #expect(!seat.adoptedWindows.contains { $0.id == 212 })
        #expect(FakeGeometry.virtual.contains(try #require(sensing.additionalWindows[211]).frame))
        seat.stopWindowFollowing()
    }

    @Test func newSheetFollowsItsHostWithoutPositionWrites() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let reader = ControlledSurfaceReader(sensing: sensing)
        let seat = makeSeat(sensing: sensing, placing: placing, reader: reader)
        let host = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        var movedWindows: [Int] = []
        placing.onWindowMove = { window, origin in
            movedWindows.append(window.windowNumber)
            let frame = CGRect(origin: origin, size: window.frame.size)
            placing.bodyFrames[window.windowNumber] = frame
            if window.windowNumber == host.id {
                sensing.geometry = window.replacingFrame(frame)
                if let sheet = sensing.additionalWindows[211] {
                    let moved = sheet.replacingFrame(CGRect(x: origin.x + 100, y: origin.y + 50,
                        width: sheet.frame.width, height: sheet.frame.height))
                    sensing.additionalWindows[211] = moved
                    placing.bodyFrames[211] = moved.frame
                }
            }
            sensing.surfaces = sensing.knownWindowNumbers.compactMap { number in
                sensing.windowGeometry(of: number).map {
                    WindowSurface(reference: $0, level: 0, isVisible: true)
                }
            }
        }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        let sheet = FakeGeometry.reference(frame: CGRect(x: 300, y: 200, width: 300, height: 200),
            windowNumber: 211)
        sensing.additionalWindows[211] = sheet
        placing.bodyFrames[211] = sheet.frame
        sensing.surfaces?.append(WindowSurface(reference: sheet, level: 0, isVisible: true))
        reader.roles[211] = .dialog
        reader.modals[211] = .window(try #require(host.reference.identity))
        let report = try await seat.takeBackApplication()
        #expect(report.failures.isEmpty)
        let adoptedSheet = try #require(seat.adoptedWindows.first { $0.id == 211 })
        #expect(adoptedSheet.owesNoReturn)
        #expect(!movedWindows.contains(211))
    }

    @Test func closedWindowIsNotReadopted() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        sensing.destroyed.insert(window.id)
        sensing.geometry = nil
        sensing.surfaces = []
        let count = placing.moves.count
        let report = try await seat.takeBackApplication()
        #expect(report.failures.isEmpty)
        #expect(seat.adoptedWindows.isEmpty)
        #expect(placing.moves.count == count)
    }

    @Test(arguments: [false, true], [false, true])
    func handbackRestoresPreviousFocus(closeAllWindows: Bool, restoreFails: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let sender = FakeSender()
        let user = FakeGeometry.reference(frame: CGRect(x: 30, y: 40, width: 600, height: 400),
                                          processID: 99, windowNumber: 900)
        sensing.additionalWindows[900] = user
        sensing.focusedUserWindow = user
        sensing.frontmostProcessID = user.processID
        let seat = makeSeat(sensing: sensing, placing: placing, sender: sender)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
            virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
            windows: [user, window.reference])
        var restored: [WindowReference] = []
        var handbackStates: [SeatState] = []
        let log = MultiWindowTests.EventLog(seat)
        defer { log.stop() }
        let recovery = UserFocusRecovery(sensing: sensing, gate: sender.gate,
            adopted: { seat.adoptedWindows.map(\.reference) },
            restore: { restored.append($0); return restoreFails ? -1 : 0 },
            isFrontmost: { pid in !seat.adoptedWindows.isEmpty && sensing.frontmostProcessID == pid },
            isLendingProcessFrontmost: { process in
                process == window.reference.identity?.process && sensing.frontmostProcessID == process.processID
            },
            allowsHumanActivation: { seat.allowsHumanActivation(processID: $0) },
            changed: { report in
                seat.focusRecoveryChanged(report)
                handbackStates.append(seat.state)
            })
        seat.focusRecovery = recovery
        defer { recovery.stop() }
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        let token = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in
            sensing.frontmostProcessID = FakeGeometry.targetPID
            sensing.targetIsActive = true
        }
        recovery.activationChanged(to: FakeGeometry.targetPID)
        #expect(restored.isEmpty)
        #expect(seat.inputPauseReasons.contains(.humanIntervention))
        if closeAllWindows {
            sensing.destroyed.insert(window.id)
            sensing.geometry = nil
            sensing.surfaces = []
            sensing.focusRecoverySnapshot = FocusRecoverySnapshot(topologyIsValid: true,
                virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical], windows: [user])
        }
        _ = try await seat.takeBackApplication()
        try await seat.endLendingHumanInput(token)
        #expect(restored.map(\.identity) == [user.identity])
        #expect(seat.lastFocusRecovery?.timing.activationSource == .applicationLendingHandback)
        if restoreFails {
            #expect(seat.state == .waiting)
            #expect(seat.lastFocusRecovery?.outcome == .waitingForUser)
            #expect(seat.inputPauseReasons.contains(.focusRecovery))
            if let record = seat.session[window.id] {
                #expect(seat.currentIssues(for: record).contains(.targetActivated))
            }
            return
        }
        #expect(!handbackStates.contains(.waiting))
        #expect(seat.state == .ready)
        if let record = seat.session[window.id] {
            #expect(!seat.currentIssues(for: record).contains(.targetActivated))
            sensing.fenceIsActive = false
            #expect(seat.currentIssues(for: record).contains(.fenceUnavailable))
            sensing.fenceIsActive = true
            let otherLifetime = FakeGeometry.identity(lifetime: 2).process
            #expect(!recovery.isHandingBackApplication(otherLifetime))
        }
        sensing.frontmostProcessID = user.processID
        sensing.targetIsActive = false
        recovery.verify()
        recovery.verify()
        #expect(seat.inputPauseReasons.isEmpty)
        #expect(!handbackStates.contains(.waiting))
        await log.drain()
        #expect(!log.events.contains(.issueDetected(.targetActivated, cause: nil)))
        #expect(!log.events.contains {
            if case .seatStateChanged(_, .waiting, _) = $0 { return true }
            return false
        })
        if let record = seat.session[window.id] {
            sensing.frontmostProcessID = window.reference.processID
            sensing.targetIsActive = true
            #expect(seat.currentIssues(for: record).contains(.targetActivated))
            recovery.activationChanged(to: window.reference.processID, source: .workspaceNotification)
            #expect(seat.state == .waiting)
            await log.drain()
            #expect(log.events.contains(.issueDetected(.targetActivated, cause: nil)))
        }
    }

    @Test func thumbnailWithoutBodyRefusesBeforeMoving() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        sensing.geometry = window.reference.replacingFrame(CGRect(x: 20, y: 100, width: 100, height: 100))
        sensing.surfaces = [WindowSurface(reference: try #require(sensing.geometry), level: 0, isVisible: true)]
        _ = try seat.beginHumanInput()
        let moves = placing.moves.count
        await #expect(throws: ApplicationLendingRefusal.self) {
            try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        }
        #expect(placing.moves.count == moves)
        #expect(!seat.isApplicationLent)
    }

    @Test func overlappingOversizedWindowStaysPutAtLeaseEnd() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let large = CGRect(x: 1600, y: 20, width: 1800, height: 800)
        sensing.geometry = window.reference.replacingFrame(large)
        placing.bodyFrame = large
        placing.onMove = { origin in
            let frame = CGRect(origin: origin, size: large.size)
            sensing.geometry = window.reference.replacingFrame(frame)
            placing.bodyFrame = frame
        }
        _ = try seat.beginHumanInput()
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        #expect(report.wasClamped)
        #expect(report.failures.isEmpty)
        #expect(FakeGeometry.virtual.intersects(try #require(sensing.geometry).frame))
        let moves = placing.moves.count
        await seat.abandonHumanInput(reason: .leaseEnded)
        #expect(seat.adoptedWindows.isEmpty)
        #expect(seat.didAbandonApplicationLending)
        #expect(placing.moves.count == moves)
    }

    @Test func unfinishedTransferRefusesLending() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        _ = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        _ = try seat.beginHumanInput()
        seat.beginTransfer()
        defer { seat.endTransfer() }
        let moves = placing.moves.count
        await #expect(throws: SessionFailure.self) {
            try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        }
        #expect(placing.moves.count == moves)
        #expect(!seat.isApplicationLent)
    }

    @Test func closeDrainsLendingBeforeForgettingWindows() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        _ = try seat.beginHumanInput()
        var activation: CheckedContinuation<Void, Never>?
        let lending = Task {
            try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in
                await withCheckedContinuation { activation = $0 }
            }
        }
        guard await AppWindowFollowTests.settle({ activation != nil }, within: 3) else {
            lending.cancel()
            Issue.record("Lending did not reach activation")
            return
        }
        let close = Task { await seat.abandonHumanInput(reason: .leaseEnded) }
        #expect(await AppWindowFollowTests.settle({ seat.lendingEnding }, within: 3))
        activation?.resume()
        let report = try await lending.value
        await close.value
        #expect(!report.failures.isEmpty)
        #expect(!seat.isApplicationLent)
        #expect(!seat.hasHumanInput)
        #expect(seat.didAbandonApplicationLending)
        #expect(seat.adoptedWindows.isEmpty)
    }

    @Test(arguments: [false, true])
    func lentMoveRefusedOnceIsTriedAgain(staysRefused: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: window.reference.frame.size))
        }
        // Safari answered the first write after its activation as not settable.
        let refusal = DisplayFailure.attributeNotSettable("AXPosition")
        if staysRefused { placing.moveError = refusal } else { placing.moveErrors = [refusal] }
        _ = try seat.beginHumanInput()
        let moves = placing.moves.count
        let report = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        #expect(placing.moves.count == moves + 2)
        #expect(report.moves.count == (staysRefused ? 0 : 1))
        #expect(report.failures.map(\.windowNumber) == (staysRefused ? [window.id] : []))
    }

    @Test(arguments: [false, true])
    func takeBackActivatesAWindowTheRaiseLeftInTheStrip(comesOut: Bool) async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let before = window.reference.frame
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: before.size))
        }
        let token = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        sensing.surfaces = [WindowSurface(reference: try #require(sensing.geometry), level: 0, isVisible: true)]
        // The returning window lands in the virtual display's Stage Manager strip and AXRaise leaves it there.
        let strip = CGRect(x: FakeGeometry.virtual.minX + 15, y: 600, width: 95, height: 108)
        placing.onMove = { _ in sensing.geometry = window.reference.replacingFrame(strip) }
        placing.stageError = DisplayFailure.stageNotConfirmed(windowNumber: window.id, lastFrame: strip)
        var broughtOut: [Int] = []
        let report = try await seat.takeBackApplication(willMoveAll: nil) { stashed in
            broughtOut.append(stashed.windowNumber)
            if comesOut { sensing.geometry = window.reference.replacingFrame(before) }
        }
        #expect(broughtOut == [window.id])
        #expect(report.failures.isEmpty == comesOut)
        #expect(sensing.geometry?.frame == (comesOut ? before : strip))
        if comesOut { try await seat.endHumanInput(token) }
    }

    @Test func takeBackShowsAHiddenApplicationBeforeMoving() async throws {
        let sensing = FakeSensing()
        let placing = FakePlacing()
        let seat = makeSeat(sensing: sensing, placing: placing)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        let before = window.reference.frame
        placing.onMove = { origin in
            sensing.geometry = window.reference.replacingFrame(CGRect(origin: origin, size: before.size))
        }
        _ = try seat.beginHumanInput()
        _ = try await seat.lendApplication(visibleFrame: FakeGeometry.physical) { _ in }
        let lent = try #require(sensing.geometry)
        // Command-H: the window server no longer lists the window, though it still names it.
        sensing.geometry = nil
        sensing.orderedOut = [window.id]
        let moves = placing.moves.count
        var shown: [Int] = []
        let report = try await seat.takeBackApplication(willMoveAll: { _ in
            #expect(shown == [window.id], "the application is shown before the frames are offered")
        }) { hidden in
            shown.append(hidden.windowNumber)
            #expect(placing.moves.count == moves)
            sensing.orderedOut = []
            sensing.geometry = lent
        }
        #expect(shown == [window.id])
        #expect(report.failures.isEmpty)
        #expect(sensing.geometry?.frame == before)
    }

}
