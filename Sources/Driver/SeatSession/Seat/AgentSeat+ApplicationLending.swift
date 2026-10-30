//
//  AgentSeat+ApplicationLending.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import Foundation
import os
import SeatCore
import SeatInput
import VirtualScreens

/// ApplicationLendingState keeps the virtual frames and process lifetime across physical use.
/// MainActor owns the state; lease cleanup waits for an in-flight placement before forgetting it.
struct ApplicationLendingState {
    let process: ProcessIdentity
    let records: [WindowRecord]
    var report: ApplicationLendingReport
    let baseline: Set<WindowIdentity>
}

extension AgentSeat {
    public var isApplicationLent: Bool { applicationLending != nil }

    package var lentApplicationHasExited: Bool {
        guard let process = applicationLending?.process else { return false }
        return sensing.isActive(processID: process.processID) == nil
    }

    func isLent(_ window: WindowReference) -> Bool {
        guard let process = applicationLending?.process else { return false }
        return window.identity?.process == process
    }

    /// Lends all held windows of the current application after its worker has drained.
    /// Activation raises the largest moved window; WindowServer verifies its full size and order.
    /// `screenFrame` includes the display's menu-bar and Dock areas; placement uses `visibleFrame`.
    /// Partial moves are reported and remain lent until take-back or lease abandonment.
    public func lendApplication(
        visibleFrame: CGRect,
        screenFrame: CGRect? = nil,
        around anchor: CGRect? = nil,
        willMove: ((WindowReference, CGRect) async -> Void)? = nil,
        preactivate: ((WindowReference) async -> Void)? = nil,
        activate: (WindowReference) async throws -> Void
    ) async throws -> ApplicationLendingReport {
        try await lendApplication(visibleFrame: visibleFrame, screenFrame: screenFrame, around: anchor,
                                  willMove: willMove, willMoveAll: nil, preactivate: preactivate, activate: activate)
    }

    /// Supplies the complete layout to presentation before activation or placement begins.
    package func lendApplication(
        visibleFrame: CGRect,
        screenFrame: CGRect? = nil,
        around anchor: CGRect? = nil,
        lendingFrames: [Int: CGRect] = [:],
        willMove: ((WindowReference, CGRect) async -> Void)? = nil,
        willMoveAll: (([WindowReference]) async -> Void)?,
        preactivate: ((WindowReference) async -> Void)? = nil,
        activate: (WindowReference) async throws -> Void
    ) async throws -> ApplicationLendingReport {
        if let lending = applicationLending, !lendingOperationInFlight { return lending.report }
        let screenBounds = screenFrame ?? visibleFrame
        guard !lendingOperationInFlight, !lendingEnding, !isTearingDown,
              state != .failed, lendingHasStableBoundary,
              inputPauseReasons.contains(.humanIntervention),
              visibleFrame.width > 0, visibleFrame.height > 0,
              !visibleFrame.isInfinite, !visibleFrame.isNull,
              !screenBounds.isInfinite, !screenBounds.isNull, screenBounds.contains(visibleFrame),
              !visibleFrame.intersects(sensing.virtualDisplayBounds) else {
            throw SessionFailure.seatNotReady(state)
        }
        guard let process = currentTarget?.reference.identity?.process ?? assignmentKit.lifecycle.current?.instance else {
            throw ApplicationLendingRefusal.noWindows
        }
        var records = session.records.values.filter { $0.window.reference.identity?.process == process }
            .sorted {
                if $0.window.owesNoReturn != $1.window.owesNoReturn { return !$0.window.owesNoReturn }
                return $0.window.id < $1.window.id
            }
        guard !records.isEmpty else { throw ApplicationLendingRefusal.noWindows }
        guard state.acceptsCommands else { throw SessionFailure.seatNotReady(state) }
        var refreshedSurfaces: [WindowSurface]?
        do {
            records = try preflightLending(records)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let surfaces = sensing.windowSurfaces(ownedBy: [process.processID]) else {
                throw ApplicationLendingRefusal.inventoryUnavailable
            }
            refreshedSurfaces = surfaces
            let identities = Set(surfaces.compactMap { $0.reference.identity })
            records = records.filter { record in
                record.window.reference.identity.map { identities.contains($0) } == true
            }
            guard !records.isEmpty else { throw ApplicationLendingRefusal.noWindows }
            do { records = try preflightLending(records) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ApplicationLendingRefusal.refreshFailed(String(describing: error)) }
        }
        guard !records.isEmpty else { throw ApplicationLendingRefusal.noWindows }
        let frames = records.map { $0.window.reference.frame }
        guard let surfaces = refreshedSurfaces ?? sensing.windowSurfaces(ownedBy: [process.processID]) else {
            throw ApplicationLendingRefusal.inventoryUnavailable
        }
        // The largest window is the one activated below.
        let front = frames.indices.max { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height }
        let layout = ApplicationLendingLayout(
            frames: frames,
            visibleFrame: visibleFrame,
            anchor: anchor.flatMap { anchor in front.map { ($0, CGPoint(x: anchor.midX, y: anchor.midY)) } },
            destinations: records.map { lendingFrames[$0.window.id] }
        )
        var report = ApplicationLendingReport()
        report.wasClamped = layout.wasClamped
        report.personHasControl = true
        applicationLending = ApplicationLendingState(
            process: process, records: records, report: report,
            baseline: Set(surfaces.compactMap { $0.reference.identity })
        )
        focusRecovery?.beginApplicationLending(process: process)
        lendingOperationInFlight = true
        beginTransfer()
        defer {
            applicationLending?.report = report
            lendingOperationInFlight = false
            endTransfer()
            logLending("lend", report)
        }
        if let willMoveAll {
            await willMoveAll(records.enumerated().map { index, record in
                record.window.reference.replacingFrame(layout.frames[index])
            })
            try checkLendingContinues()
        }
        if let willMove, let front {
            await willMove(records[front].window.reference, layout.frames[front])
            try checkLendingContinues()
        }
        if let preactivate, let front {
            // Under Stage Manager a window that lands while its app is inactive goes to the strip first and slides in
            // on activation. Activating first lands the windows straight in the current stage; activation is still
            // performed and verified after the moves.
            await preactivate(records[front].window.reference)
            try Task.checkCancellation()
        }
        for (index, record) in records.enumerated() {
            do {
                try checkLendingContinues()
                let window = record.window.reference
                guard sensing.windowGeometry(of: window.windowNumber)?.hasSameIdentity(as: window) == true else {
                    throw SeatInterruption(issues: [.identityChanged])
                }
                if !record.window.owesNoReturn {
                    do { try placing.move(window, to: layout.frames[index].origin) }
                    catch is DisplayFailure {
                        // Refused once right after the activation above, movable later (Safari).
                        await EventLoopWait.sleep(.milliseconds(150))
                        try checkLendingContinues()
                        guard sensing.windowGeometry(of: window.windowNumber)?.hasSameIdentity(as: window) == true else {
                            throw SeatInterruption(issues: [.identityChanged])
                        }
                        try placing.move(window, to: layout.frames[index].origin)
                    }
                }
                let after = try await confirmLentFrame(window, expected: layout.frames[index])
                if let identity = window.identity {
                    report.moves.append(.init(window: identity, before: frames[index], after: after))
                }
            } catch {
                report.failures.append(.init(windowNumber: record.window.id, reason: String(describing: error)))
            }
        }
        if let largest = report.moves.max(by: { $0.after.width * $0.after.height < $1.after.width * $1.after.height }) {
            let window = WindowReference(identity: largest.window, frame: largest.after)
            report.activationWindow = largest.window
            report.activation = .unverified
            for attempt in 1 ... 2 {
                do {
                    try checkLendingContinues()
                    guard sensing.windowGeometry(of: window.windowNumber)?.hasSameIdentity(as: window) == true else {
                        throw SeatInterruption(issues: [.identityChanged])
                    }
                    report.activationAttempts = attempt
                    try await activate(window)
                    try await confirmLendingActivation(window, on: screenBounds)
                    report.activation = .verified
                    break
                } catch {
                    let identityChanged = (error as? SeatInterruption)?.issues.contains(.identityChanged) == true
                    if attempt == 2 || error is CancellationError || identityChanged {
                        report.failures.append(.init(windowNumber: window.windowNumber,
                            reason: "Activation unverified; the person retains control: \(error)"))
                        break
                    }
                    await EventLoopWait.sleep(.milliseconds(150))
                }
            }
        }
        for move in report.moves {
            let reference = WindowReference(identity: move.window, frame: move.after)
            do { _ = try await confirmLentFrame(reference, expected: move.after) }
            catch {
                report.failures.append(.init(windowNumber: move.window.windowNumber,
                    reason: "Placement after activation: \(error)"))
            }
        }
        return report
    }

    /// Captures all bodies before any move. A raise can stash a sibling immediately.
    private func preflightLending(_ held: [WindowRecord]) throws -> [WindowRecord] {
        var records = held
        for index in records.indices {
            let record = records[index]
            guard let live = sensing.windowGeometry(of: record.window.id),
                  live.hasSameIdentity(as: record.window.reference) else {
                throw SeatInterruption(issues: [.identityChanged])
            }
            let measuredBody = try placing.frame(of: live)
            guard measuredBody != nil || !SeatWindowSession.readsAsThumbnail(
                serverSize: live.frame.size, fullSize: record.operationalSize
            ) else { throw SeatInterruption(issues: [.windowStashed]) }
            let body = measuredBody ?? live.frame
            guard sensing.windowGeometry(of: live.windowNumber)?.hasSameIdentity(as: live) == true else {
                throw SeatInterruption(issues: [.identityChanged])
            }
            guard body.width > 0, body.height > 0, !body.isInfinite, !body.isNull,
                  sensing.virtualDisplayBounds.contains(body) else {
                throw SeatInterruption(issues: [.geometryChanged])
            }
            records[index].window = record.window.withReference(live.replacingFrame(body))
        }
        return records
    }

    /// WindowServer, not the AX body, proves full size and front-to-back order on this screen.
    private func confirmLendingActivation(_ window: WindowReference, on screen: CGRect) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        var previous: CGRect?
        var issue: SeatIssue = .windowUnavailable
        while ContinuousClock.now < deadline {
            try checkLendingContinues()
            if let server = sensing.windowGeometry(of: window.windowNumber) {
                guard server.hasSameIdentity(as: window) else {
                    throw SeatInterruption(issues: [.identityChanged])
                }
                let fullSize = VirtualWindowPlacementCheck.framesMatch(server.frame, window.frame,
                    tolerance: VirtualWindowPlacementCheck.crossSourceTolerance)
                let inFront = fullSize && sensing.windowIsFrontmost(window, on: screen) == true
                let after = sensing.windowGeometry(of: window.windowNumber)
                guard after?.hasSameIdentity(as: window) == true else {
                    throw SeatInterruption(issues: [.identityChanged])
                }
                if inFront, after?.frame == server.frame {
                    if previous == server.frame { return }
                    previous = server.frame
                } else {
                    previous = nil
                }
                issue = SeatWindowSession.readsAsThumbnail(serverSize: server.frame.size, fullSize: window.frame.size)
                    ? .windowStashed : .geometryChanged
            } else {
                previous = nil
                issue = .windowUnavailable
            }
            await EventLoopWait.step(.milliseconds(20))
        }
        throw SeatInterruption(issues: [issue])
    }

    /// Readopts the original windows at their recorded virtual frames, plus windows born while lent.
    /// Missing geometry is a failure unless destruction or process exit is positively established.
    /// Every exit re-arms the guards. Failures retain the human input pause.
    public func takeBackApplication() async throws -> ApplicationLendingReport {
        try await takeBackApplication(willMoveAll: nil)
    }

    /// Reads current AX bodies and attested identities before the first take-back move.
    /// `bringOut` shows a hidden application, or activates it on a window AXRaise left in the
    /// Stage Manager strip; each case is tried once per take-back.
    package func takeBackApplication(
        willMoveAll: (([WindowReference]) async -> Void)?,
        bringOut: ((WindowReference) async throws -> Void)? = nil
    ) async throws -> ApplicationLendingReport {
        guard let lending = applicationLending else { return ApplicationLendingReport() }
        guard !lendingOperationInFlight, !lendingEnding else {
            throw SessionFailure.assignmentStillInUse(.commandInFlight)
        }
        lendingOperationInFlight = true
        beginTransfer()
        var report = ApplicationLendingReport()
        defer {
            applicationLending = nil
            lendingOperationInFlight = false
            endTransfer()
            foldCurrentReading()
            if !report.failures.isEmpty || report.applicationVanished { focusRecovery?.endApplicationLending() }
            logLending("take-back", report)
        }
        if sensing.isActive(processID: lending.process.processID) == nil {
            report.applicationVanished = true
            for record in lending.records { forgetRecord(record.window.id) }
            endAssignmentAndObservation(reason: .requestedByConsumer)
            return report
        }
        if let bringOut, let hidden = lending.records.first(where: {
            sensing.windowGeometry(of: $0.window.id) == nil && sensing.windowIsOrderedOut($0.window.reference)
        })?.window.reference {
            // A hidden application has ordered its windows out; shown, they return where the person left them.
            // One still missing afterwards is reported below as unavailable.
            try? await bringOut(hidden)
            let deadline = ContinuousClock.now + .seconds(1)
            while sensing.windowGeometry(of: hidden.windowNumber) == nil, ContinuousClock.now < deadline {
                await EventLoopWait.step(.milliseconds(20))
                try checkLendingContinues()
            }
        }
        let surfaces = sensing.windowSurfaces(ownedBy: [lending.process.processID])
        if surfaces == nil {
            report.failures.append(.init(windowNumber: 0, reason: "Application window inventory unavailable"))
        }
        if let willMoveAll {
            var current: [WindowReference] = []
            for record in lending.records {
                let window = record.window.reference
                guard let live = sensing.windowGeometry(of: window.windowNumber), live.hasSameIdentity(as: window),
                      !sensing.windowIsDestroyed(window) else { continue }
                do {
                    let body = try placing.frame(of: live) ?? live.frame
                    guard body.width > 0, body.height > 0, !sensing.virtualDisplayBounds.contains(body.origin) else { continue }
                    guard sensing.windowGeometry(of: window.windowNumber)?.hasSameIdentity(as: window) == true else { continue }
                    current.append(live.replacingFrame(body))
                } catch {
                    // An unreadable frame cannot be offered as the person's current placement.
                    continue
                }
            }
            // Include windows opened during human control, which the take-back inventory also readopts.
            let known = Set(lending.records.compactMap { $0.window.reference.identity }).union(lending.baseline)
            for surface in surfaces ?? [] {
                guard let identity = surface.reference.identity, identity.process == lending.process,
                      !known.contains(identity),
                      AppWindowInventory.isTransferable(surface, menuLevel: Int(CGWindowLevelForKey(.popUpMenuWindow))),
                      let live = sensing.windowGeometry(of: identity.windowNumber), live.identity == identity else { continue }
                do {
                    let body = try placing.frame(of: live) ?? live.frame
                    guard body.width > 0, body.height > 0, !sensing.virtualDisplayBounds.contains(body.origin) else { continue }
                    guard sensing.windowGeometry(of: identity.windowNumber)?.identity == identity else { continue }
                    current.append(live.replacingFrame(body))
                } catch { continue }
            }
            await willMoveAll(current)
            try checkLendingContinues()
        }
        var broughtOutOfStrip = false
        for record in lending.records {
            let window = record.window.reference
            if sensing.windowIsDestroyed(window) {
                forgetRecord(window.windowNumber)
                noteSurfaceGone(window.windowNumber)
                continue
            }
            do {
                try checkLendingContinues()
                guard let live = sensing.windowGeometry(of: window.windowNumber), live.hasSameIdentity(as: window) else {
                    throw SeatInterruption(issues: [.windowUnavailable])
                }
                let body = try placing.frame(of: live) ?? live.frame
                // The person's size comes back with the window when it still fits at its virtual position.
                let kept = CGRect(origin: window.frame.origin, size: body.size)
                let target = sensing.virtualDisplayBounds.contains(kept) ? kept : window.frame
                if !record.window.owesNoReturn {
                    if body.size != target.size { try placing.resize(live, to: target.size) }
                    try placing.move(live, to: target.origin)
                }
                let placed = live.replacingFrame(CGRect(origin: live.frame.origin, size: target.size))
                let confirmed: (reference: WindowReference, body: CGRect)
                do {
                    confirmed = try await confirmPlacement(
                        of: placed, expectedOrigin: target.origin, within: sensing.virtualDisplayBounds,
                        takenInPlace: false,
                        wasStashed: SeatWindowSession.readsAsThumbnail(serverSize: live.frame.size, fullSize: target.size)
                    )
                } catch DisplayFailure.stageNotConfirmed where bringOut != nil && !broughtOutOfStrip {
                    // AXRaise left it in the virtual display's Stage Manager strip (Safari);
                    // activating the application on it is what a click on the thumbnail does.
                    broughtOutOfStrip = true
                    try await bringOut?(placed)
                    confirmed = try await confirmPlacement(
                        of: placed, expectedOrigin: target.origin, within: sensing.virtualDisplayBounds,
                        takenInPlace: false, wasStashed: true
                    )
                }
                try checkLendingContinues()
                guard VirtualWindowPlacementCheck.framesMatch(confirmed.reference.frame, target,
                    tolerance: VirtualWindowPlacementCheck.crossSourceTolerance) else {
                    throw SeatInterruption(issues: [.geometryChanged])
                }
                var held = record.window.withReference(confirmed.reference)
                if target.size != window.frame.size {
                    // The person's size is also the one the window is returned at when the seat releases it.
                    held = held.withReturnSize(body: target.size, server: confirmed.reference.frame.size)
                }
                session[window.windowNumber]?.window = held
                session[window.windowNumber]?.operationalSize = confirmed.body.size
                if let identity = window.identity {
                    report.moves.append(.init(window: identity, before: body, after: confirmed.reference.frame))
                }
            } catch {
                report.failures.append(.init(windowNumber: window.windowNumber, reason: String(describing: error)))
            }
        }
        var seen = lending.baseline.union(lending.records.compactMap { $0.window.reference.identity })
        for pass in 0 ..< 4 {
            foldLendingTakeBackReading()
            guard let latest = sensing.windowSurfaces(ownedBy: [lending.process.processID]) else {
                if surfaces != nil {
                    report.failures.append(.init(windowNumber: 0, reason: "Take-back inventory became unavailable"))
                }
                break
            }
            let candidates = latest.filter { surface in
                guard let identity = surface.reference.identity else { return false }
                return identity.process == lending.process && !seen.contains(identity)
                    && AppWindowInventory.isTransferable(surface, menuLevel: Int(CGWindowLevelForKey(.popUpMenuWindow)))
            }
            if candidates.isEmpty { break }
            for surface in candidates {
                let window = surface.reference
                guard let identity = window.identity else { continue }
                seen.insert(identity)
                if pass == 3 {
                    report.failures.append(.init(windowNumber: window.windowNumber,
                        reason: "A new window appeared after the take-back inventory limit"))
                    continue
                }
                do {
                    try checkLendingContinues()
                    guard let body = try placing.frame(of: window), body.width > 0, body.height > 0 else {
                        throw SeatInterruption(issues: [.windowUnavailable])
                    }
                    let attached = selectionKit.attachedHost(of: identity) != nil
                    guard !attached || sensing.virtualDisplayBounds.contains(body) else {
                        throw SeatInterruption(issues: [.geometryChanged])
                    }
                    let adopted = try await integrateDetectedWindow(
                        window.replacingFrame(body), platform: platformForDetected(window),
                        takenInPlace: attached
                    )
                    try checkLendingContinues()
                    report.moves.append(.init(window: identity, before: body, after: adopted.reference.frame))
                } catch {
                    report.failures.append(.init(windowNumber: window.windowNumber, reason: String(describing: error)))
                }
            }
        }
        if let target = session.currentTarget?.window.reference {
            seatGuard = SeatGuard(target: target, displayID: displayID, displayBounds: sensing.virtualDisplayBounds)
        }
        report.personHasControl = !report.failures.isEmpty
        return report
    }

    /// Arms attributed lending handback outside a command Turn, after all take-back placements succeeded.
    package func endLendingHumanInput(_ token: InputCommandGate.HumanInput) async throws {
        beginTransfer()
        requestsLendingHandback = true
        defer {
            requestsLendingHandback = false
            focusRecovery?.endApplicationLending()
            endTransfer()
        }
        try await endHumanInput(token)
    }

    /// Leaves physical and unreadable lent windows where the person put them.
    /// Only a positively still-virtual window keeps its ordinary return obligation.
    func abandonApplicationLending() async {
        guard applicationLending != nil else { return }
        didAbandonApplicationLending = true
        lendingEnding = true
        while lendingOperationInFlight { await EventLoopWait.sleep(.milliseconds(20)) }
        defer {
            applicationLending = nil
            lendingEnding = false
            focusRecovery?.endApplicationLending()
        }
        guard let lending = applicationLending else { return }
        for record in lending.records {
            let window = record.window.reference
            if sensing.windowIsDestroyed(window) {
                forgetRecord(window.windowNumber)
                continue
            }
            let wasMoved = lending.report.moves.contains { $0.window == window.identity }
            var currentBody: CGRect?
            if let live = sensing.windowGeometry(of: window.windowNumber), live.hasSameIdentity(as: window) {
                do {
                    currentBody = try placing.frame(of: live)
                    if currentBody == nil, !SeatWindowSession.readsAsThumbnail(
                        serverSize: live.frame.size, fullSize: record.operationalSize
                    ) { currentBody = live.frame }
                } catch { /* A confirmed loan can be relinquished without another AX reading. */ }
            }
            if let body = currentBody {
                // Activation can return an already confirmed loan to the virtual display.
                if sensing.virtualDisplayBounds.contains(body.origin) { continue }
            } else if !wasMoved {
                // An unconfirmed transfer has no physical proof on which to erase its obligation.
                continue
            }
            if let identity = window.identity { lentWindowsLeftWithPerson.insert(identity) }
            forgetRecord(window.windowNumber)
            noteSurfaceGone(window.windowNumber)
        }
        if session.records.isEmpty { endAssignmentAndObservation(reason: .requestedByConsumer) }
    }

    private func checkLendingContinues() throws {
        try Task.checkCancellation()
        guard !lendingEnding, !isTearingDown, state != .failed, applicationLending != nil else {
            throw CancellationError()
        }
    }

    /// AX bodies remain full size when Stage Manager exposes only a server thumbnail.
    /// Both readings must identify the same lifetime; two agreeing bodies confirm the translation.
    private func confirmLentFrame(_ window: WindowReference, expected: CGRect) async throws -> CGRect {
        let deadline = ContinuousClock.now + .seconds(2)
        var previous: CGRect?
        while ContinuousClock.now < deadline {
            try checkLendingContinues()
            if let server = sensing.windowGeometry(of: window.windowNumber), server.hasSameIdentity(as: window) {
                let body = try placing.frame(of: server) ?? server.frame
                guard sensing.windowGeometry(of: window.windowNumber)?.hasSameIdentity(as: window) == true else {
                    throw SeatInterruption(issues: [.identityChanged])
                }
                if VirtualWindowPlacementCheck.framesMatch(body, expected,
                    tolerance: VirtualWindowPlacementCheck.crossSourceTolerance) {
                    if previous == body { return body }
                    previous = body
                } else { previous = nil }
            } else { previous = nil }
            await EventLoopWait.step(.milliseconds(20))
        }
        throw SeatInterruption(issues: [.geometryChanged])
    }

    private func logLending(_ operation: String, _ report: ApplicationLendingReport) {
        let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Session")
        let moves = report.moves.map { "\($0.window.windowNumber): \($0.before) -> \($0.after)" }.joined(separator: "; ")
        let failures = report.failures.map { "\($0.windowNumber): \($0.reason)" }.joined(separator: "; ")
        log.notice("""
            application \(operation, privacy: .public): moved \(report.moves.count), \
            frames \(moves, privacy: .public), clamp \(report.wasClamped), \
            failures \(failures, privacy: .public), vanished \(report.applicationVanished), \
            activation \(report.activation.rawValue, privacy: .public), \
            activationWindow \(report.activationWindow?.windowNumber ?? 0), \
            attempts \(report.activationAttempts), personHasControl \(report.personHasControl)
            """)
    }
}
