//
//  BrokeredAutomationSessionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import SeatCore
import SeatDriving
import SeatSession
import TestScratch
import Testing
@testable import SeatBroker

/// A worker's desktop session over the broker's queue, driven with the queue's own seats: a
/// session costs one allocation and raises no display until something is adopted, so the lease
/// is real and nothing here reaches the desktop. The grants and the opening are supplied in
/// place of macOS, keeping their order: the grants before the queue, the opening on the seat
/// the queue granted. What the real opening and the borrowed engine do on a display is the live
/// row in `WorkerAgentsTests`.
@MainActor
@Suite("A worker's desktop session through the broker")
struct BrokeredAutomationSessionTests {

    private static let workerID = UUID()
    private static let label    = workerID.uuidString

    private final class RunningFixture: NSRunningApplication {
        override var isTerminated: Bool { false }
        override var bundleIdentifier: String? { "test.process" }
        override var processIdentifier: pid_t { ProcessInfo.processInfo.processIdentifier }
    }

    private struct Opened: Error {}

    @Test func a5KeepsLegacyScreenViewAvailableAcrossWindowInventoryChanges() async throws {
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(SeatBroker(), perceiving: { _, _ in scene },
                                   running: { _ in RunningFixture() }) { _, _, _ in
            (TargetApp(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "test.process",
                       name: "Test", bundleURL: nil, windows: []), SeatTarget())
        }
        #expect(desktop.makeScreenView(contentsScale: 2) == nil)
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(desktop.makeScreenView(contentsScale: 2) is LivePreviewView)
        desktop.updateHeldWindows([], metadata: [:])
        #expect(desktop.hasScreen)
        #expect(desktop.makeScreenView(contentsScale: 2) is LivePreviewView)
        await desktop.close()
        #expect(desktop.heldWindows.isEmpty)
        #expect(desktop.makeScreenView(contentsScale: 2) == nil)
        #expect(desktop.makeWindowView(windowNumber: 7, contentsScale: 2) == nil)
    }

    /// Stands in for the idle window's clock: each wait is recorded and returns only when the test
    /// lets the oldest one elapse, so no test sleeps for the window. A cancelled wait is not woken,
    /// so the session's own check after the wait is what a late elapse exercises.
    @MainActor
    private final class IdleClock {
        private(set) var waits: [Duration] = []
        private var pending: [CheckedContinuation<Void, Never>] = []

        var pendingCount: Int { pending.count }

        func wait(_ window: Duration) async {
            waits.append(window)
            await withCheckedContinuation { pending.append($0) }
        }

        /// Wakes the oldest wait, once the session's release task has begun it.
        func elapseOldest() async {
            await BrokeredAutomationSessionTests.until { !self.pending.isEmpty }
            guard !pending.isEmpty else {
                Issue.record("no idle wait began")
                return
            }
            pending.removeFirst().resume()
        }

        /// Wakes every wait after scheduling settles, including cancelled waits left by earlier calls.
        func elapseAll() async {
            await BrokeredAutomationSessionTests.letTheWaitBegin()
            let waiting = pending
            pending.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

    /// The fixtures' resolution of a name: "Test" is the `test.process` their seating names; any other word is taken
    /// as the bundle ID, as `open` claims it before seating.
    static let resolvedForTheFixtures: BrokeredAutomationSession.Resolving = { $0 == "Test" ? "test.process" : $0 }

    private static func session(
        _ broker  : SeatBroker,
        workerID  : UUID = workerID,
        grantee   : String = "Braus",
        missing   : PermissionKind? = nil,
        requests  : @escaping @MainActor () -> Void = {},
        perceiving: @escaping BrokeredAutomationSession.Perceiving = BrokeredAutomationSession
            .perceivedThroughTheEngine,
        running: @escaping @MainActor (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) },
        idleWindow: Duration = BrokeredAutomationSession.idleWindow,
        waitIdle  : @escaping BrokeredAutomationSession.IdleWaiting = { try await Task.sleep(for: $0) },
        dialog    : DialogButtonPress.OpenDialog? = nil,
        lending   : @escaping BrokeredAutomationSession.FrontLending = BrokeredAutomationSession.lentThroughTheSeat,
        clickLending: @escaping BrokeredAutomationSession.FrontClickLending = BrokeredAutomationSession.lentWithClicksThroughTheSeat,
        seating   : @escaping BrokeredAutomationSession.Seating
    ) -> BrokeredAutomationSession {
        BrokeredAutomationSession(
            broker            : broker,
            workerID          : workerID,
            knowledgeDirectory: Scratch.directory("braus-brokered"),
            allowsDestructive : false,
            grantee           : grantee,
            resolving         : resolvedForTheFixtures,
            missingGrant      : { missing },
            requestGrants     : requests,
            seating           : seating,
            perceiving        : perceiving,
            runningApplication: running,
            idleWindow        : idleWindow,
            waitIdle          : waitIdle,
            readDialog        : { _ in dialog },
            lending           : lending,
            clickLending      : clickLending
        )
    }

    /// Opens a controlled running application; only the front lease's platform boundary is replaced.
    private static func frontSession(
        _ broker: SeatBroker,
        idle    : IdleClock? = nil,
        target  : SeatTarget = SeatTarget(),
        lending : @escaping BrokeredAutomationSession.FrontLending = BrokeredAutomationSession.lentThroughTheSeat,
        clickLending: @escaping BrokeredAutomationSession.FrontClickLending = BrokeredAutomationSession.lentWithClicksThroughTheSeat
    ) -> BrokeredAutomationSession {
        let scene = SceneSnapshot(
            bundleID         : "test.process",
            appName          : "Test",
            windowTitle      : "Test",
            viewportPixelSize: ViewportPixelSize(
                width : 10,
                height: 10
            ),
            elements         : []
        )
        return session(
            broker,
            perceiving: { _, _ in scene },
            running   : { _ in RunningFixture() },
            waitIdle  : { window in
                if let idle { await idle.wait(window) }
                else { try await Task.sleep(for: window) }
            },
            lending   : lending,
            clickLending: clickLending
        ) { _, _, _ in
            (TargetApp(
                pid      : ProcessInfo.processInfo.processIdentifier,
                bundleID : "test.process",
                name     : "Test",
                bundleURL: nil,
                windows  : []
            ), target)
        }
    }

    /// A controlled lease input: the same Driver vocabulary consumed by the production adapter.
    @MainActor
    private final class LeaseClicks {
        var isActive = true
        var refusal: FrontLeaseInput.Refusal?
        var attempts = 0
        var left: [(CGPoint, Int, SeatCore.Modifiers)] = []
        var right: [(CGPoint, SeatCore.Modifiers)] = []

        func requireActive() throws {
            attempts += 1
            try Task.checkCancellation()
            guard isActive else { throw FrontLeaseInput.Refusal.leaseEnded }
            if let refusal { throw refusal }
        }

        var clicks: FrontClicks {
            BrokeredAutomationSession.frontClicks(
                isActive  : { self.isActive && !Task.isCancelled },
                click     : { point, count, modifiers in
                    try self.requireActive()
                    self.left.append((point, count, modifiers))
                    return Self.receipt(at: point)
                },
                rightClick: { point, modifiers in
                    try self.requireActive()
                    self.right.append((point, modifiers))
                    return Self.receipt(at: point)
                }
            )
        }

        static func receipt(at point: CGPoint) -> FrontClicks.Receipt {
            FrontClicks.Receipt(
                processID    : 123,
                windowNumber : 456,
                location     : point,
                eventCount   : 4,
                needsRecovery: true
            )
        }
    }

    @Test("tool clicks reach the lease input with points, counts and each modifier", arguments: zip(
        [FrontClicks.Modifiers(), .command, .shift, .option, .control,
         [.command, .shift, .option, .control]],
        [SeatCore.Modifiers(), .command, .shift, .option, .control,
         [.command, .shift, .option, .control]]
    ))
    func clicksUseLeaseInput(
        tool  : FrontClicks.Modifiers,
        driver: SeatCore.Modifiers
    ) async throws {
        let target = SeatTarget()
        let input = LeaseClicks()
        var leases = 0
        let desktop = Self.frontSession(
            SeatBroker(),
            target: target,
            clickLending: { supplied, admitsDialog, bound, body in
                #expect(supplied === target)
                #expect(admitsDialog)
                #expect(bound == .seconds(7))
                leases += 1
                await body(input.clicks)
                input.isActive = false
                return .completed(afterMilliseconds: 12)
            }
        )
        _ = try await desktop.open(
            application: "Test",
            window     : nil
        )
        let session: any AutomationSessionOperating = desktop
        var retained: FrontClicks?
        let point = CGPoint(
            x: 2345,
            y: 678
        )
        let other = CGPoint(
            x: 2350,
            y: 690
        )
        let answer = await session.withFront(
            of                 : "TEST.PROCESS",
            admittingOpenDialog: true,
            atMost             : .seconds(7)
        ) { clicks in
            retained = clicks
            #expect(clicks.isActive)
            let left = try await clicks.click(
                at       : point,
                count    : 2,
                modifiers: tool
            )
            let right = try await clicks.rightClick(
                at       : other,
                modifiers: tool
            )
            try await clicks.click(at: other)
            #expect(left == LeaseClicks.receipt(at: point))
            #expect(right == LeaseClicks.receipt(at: other))
            return 42
        }
        #expect(try answer.result?.get() == 42)
        #expect(answer.outcome == .completed)
        #expect(leases == 1)
        #expect(input.left.count == 2)
        #expect(input.left.first?.0 == point)
        #expect(input.left.first?.1 == 2)
        #expect(input.left.first?.2 == driver)
        #expect(input.left.last?.0 == other)
        #expect(input.left.last?.1 == 1)
        #expect(input.left.last?.2 == [])
        #expect(input.right.count == 1)
        #expect(input.right.first?.0 == other)
        #expect(input.right.first?.1 == driver)
        let ended = try #require(retained)
        #expect(!ended.isActive)
        await #expect(throws: FrontLeaseInput.Refusal.leaseEnded) {
            _ = try await ended.click(at: point)
        }
        await #expect(throws: FrontLeaseInput.Refusal.leaseEnded) {
            _ = try await ended.rightClick(at: point)
        }
        #expect(input.left.count == 2)
        #expect(input.right.count == 1)
        await desktop.close()
    }

    @Test("click failures reach the body and its result without retry", arguments: [
        FrontLeaseInput.Refusal.leaseEnded, .outsideApplication(.zero), .windowsUnreadable
    ], [false, true])
    func clickFailuresReachBody(
        refusal: FrontLeaseInput.Refusal,
        right  : Bool
    ) async throws {
        let input = LeaseClicks()
        input.refusal = refusal
        input.isActive = refusal != .leaseEnded
        let desktop = Self.frontSession(
            SeatBroker(),
            clickLending: { _, _, _, body in
                await body(input.clicks)
                return .completed(afterMilliseconds: 1)
            }
        )
        _ = try await desktop.open(
            application: "Test",
            window     : nil
        )
        var caught: FrontLeaseInput.Refusal?
        let answer = await desktop.withFront(
            of                 : "test.process",
            admittingOpenDialog: false,
            atMost             : .seconds(1)
        ) { clicks in
            do {
                if right { try await clicks.rightClick(at: .zero) }
                else { try await clicks.click(at: .zero) }
            } catch {
                caught = error as? FrontLeaseInput.Refusal
                throw error
            }
        }
        #expect(caught == refusal)
        let result = try #require(answer.result)
        #expect(throws: refusal) { try result.get() }
        #expect(answer.outcome == .completed)
        #expect(input.attempts == 1)
        #expect(input.left.isEmpty)
        #expect(input.right.isEmpty)
        await desktop.close()
    }

    @Test("click leases reject absent, different and closed holds before lending")
    func unheldClickLeaseDoesNothing() async throws {
        var leases = 0
        var runs = 0
        let desktop = Self.frontSession(
            SeatBroker(),
            clickLending: { _, _, _, _ in
                leases += 1
                return .completed(afterMilliseconds: 0)
            }
        )
        for state in 0..<3 {
            if state == 1 {
                _ = try await desktop.open(
                    application: "Test",
                    window     : nil
                )
            }
            if state == 2 { await desktop.close() }
            let answer = await desktop.withFront(
                of                 : state == 1 ? "other.process" : "test.process",
                admittingOpenDialog: false,
                atMost             : .seconds(1)
            ) { _ in runs += 1 }
            #expect(answer.result == nil)
            #expect(answer.outcome == .notHeld)
        }
        #expect(runs == 0)
        #expect(leases == 0)
    }

    @Test("a missing Seat refuses the click lease without running its body")
    func missingSeatCannotLendClicks() async throws {
        let desktop = Self.frontSession(SeatBroker())
        _ = try await desktop.open(
            application: "Test",
            window     : nil
        )
        var runs = 0
        let answer = await desktop.withFront(
            of                 : "test.process",
            admittingOpenDialog: false,
            atMost             : .seconds(1)
        ) { _ in runs += 1 }
        #expect(answer.result == nil)
        #expect(answer.outcome == .refused(
            reason: "The front was not lent because the held application's target window could not be identified."
        ))
        #expect(runs == 0)
        await desktop.close()
    }

    @Test("only the held bundle runs inside the current target's lease, ignoring bundle ID case")
    func heldApplicationBorrowsFront() async throws {
        let target = SeatTarget()
        var insideLease = false
        var leases = 0
        let desktop = Self.frontSession(
            SeatBroker(),
            target: target
        ) { supplied, admitsDialog, bound, body in
            #expect(supplied === target)
            #expect(admitsDialog)
            #expect(bound == .seconds(7))
            leases += 1
            insideLease = true
            await body()
            insideLease = false
            return .completed(afterMilliseconds: 12)
        }
        _ = try await desktop.open(
            application: "Test",
            window     : nil
        )
        let session: any AutomationSessionOperating = desktop
        let answer = await session.withFront(
            of                 : "TEST.PROCESS",
            admittingOpenDialog: true,
            atMost             : .seconds(7)
        ) {
            #expect(insideLease)
            return 42
        }
        #expect(try answer.result?.get() == 42)
        #expect(answer.outcome == .completed)
        #expect(answer.outcome.isSuccess)
        #expect(leases == 1)
        await desktop.close()
    }

    @Test("absent, different and closed holds never run the command or borrow the front")
    func unheldApplicationDoesNothing() async throws {
        var leases = 0
        var runs = 0
        let desktop = Self.frontSession(SeatBroker()) { _, _, _, body in
            leases += 1
            await body()
            return .completed(afterMilliseconds: 0)
        }
        for bundle in ["test.process", "other.process"] {
            let answer = await desktop.withFront(
                of                 : bundle,
                admittingOpenDialog: false,
                atMost             : .seconds(1)
            ) {
                runs += 1
            }
            #expect(answer.result == nil)
            #expect(answer.outcome == .notHeld)
        }
        _ = try await desktop.open(
            application: "Test",
            window     : nil
        )
        let other = await desktop.withFront(
            of                 : "other.process",
            admittingOpenDialog: false,
            atMost             : .seconds(1)
        ) {
            runs += 1
        }
        #expect(other.result == nil)
        #expect(other.outcome == .notHeld)
        await desktop.close()
        let closed = await desktop.withFront(
            of                 : "test.process",
            admittingOpenDialog: false,
            atMost             : .seconds(1)
        ) {
            runs += 1
        }
        #expect(closed.result == nil)
        #expect(closed.outcome == .notHeld)
        #expect(runs == 0)
        #expect(leases == 0)
    }

    @Test("a held application's missing Seat refuses the lease without running the command")
    func aMissingSeatCannotLendFront() async throws {
        let desktop = Self.frontSession(SeatBroker())
        _ = try await desktop.open(
            application: "Test",
            window     : nil
        )
        var runs = 0
        let answer = await desktop.withFront(
            of                 : "test.process",
            admittingOpenDialog: false,
            atMost             : .seconds(1)
        ) {
            runs += 1
        }
        #expect(answer.outcome == .refused(
            reason: "The front was not lent because the held application's target window could not be identified."
        ))
        #expect(answer.result == nil)
        #expect(runs == 0)
        await desktop.close()
    }

    private static func borrowFront<Value: Sendable>(
        _ desktop: BrokeredAutomationSession,
        withClicks: Bool,
        _ body: @escaping @MainActor () async throws -> Value
    ) async -> (result: Result<Value, any Error>?, outcome: SessionFrontOutcome) {
        if withClicks {
            return await desktop.withFront(
                of                 : "test.process",
                admittingOpenDialog: false,
                atMost             : .seconds(5)
            ) { _ in try await body() }
        }
        return await desktop.withFront(
            of                 : "test.process",
            admittingOpenDialog: false,
            atMost             : .seconds(5),
            body
        )
    }

    @Test("each Driver lease ending reaches the tool without erasing a command's result", arguments: [
        (FrontLeaseOutcome.completed(afterMilliseconds: 1), SessionFrontOutcome.completed, true),
        (.boundReached(afterMilliseconds: 2), .boundReached, true),
        (.frontTaken(afterMilliseconds: 3), .frontTaken, true),
        (.neverInFront(afterMilliseconds: 4), .neverInFront, false),
        (.handbackNotVerified, .handbackNotVerified, true),
        (.refused(.noFocusRecovery),
         .refused(reason: "The front was not lent because this Seat cannot restore the person's focus."),
         false),
        (.refused(.seatNotReady),
         .refused(reason: "The front was not lent because the Seat is not ready for a command."),
         false),
        (.refused(.dialogOpen),
         .refused(reason: "The front was not lent because the application has an open dialog that "
             + "this command did not admit."),
         false),
        (.refused(.noUserWindow),
         .refused(reason: "The front was not lent because no window of the person's own could be "
             + "identified for handback."),
         false),
        (.refused(.targetNotPrepared),
         .refused(reason: "The front was not lent because the held application's target window "
             + "could not be identified."),
         false),
        (.refused(.frontRequestRefused),
         .refused(reason: "The front request was refused by macOS, and the command did not run."),
         false)
    ])
    func frontLeaseEndings(
        driver: FrontLeaseOutcome,
        tool  : SessionFrontOutcome,
        runs  : Bool
    ) async throws {
        for withClicks in [false, true] {
            let desktop = Self.frontSession(
                SeatBroker(),
                lending: { _, _, _, body in
                    if runs { await body() }
                    return driver
                },
                clickLending: { _, _, _, body in
                    if runs { await body(LeaseClicks().clicks) }
                    return driver
                }
            )
            _ = try await desktop.open(
                application: "Test",
                window     : nil
            )
            var calls = 0
            let answer = await Self.borrowFront(
                desktop,
                withClicks: withClicks
            ) {
                calls += 1
                return "effect already happened"
            }
            #expect(answer.outcome == tool)
            #expect(answer.outcome.isSuccess == (tool == .completed))
            #expect(!answer.outcome.reason.isEmpty)
            #expect(calls == (runs ? 1 : 0))
            if runs { #expect(try answer.result?.get() == "effect already happened") }
            else { #expect(answer.result == nil) }
            await desktop.close()
        }
    }

    @Test("a front lease keeps activity through the body and handback, and restarts idle on every exit",
          arguments: CallEnding.allCases, [false, true])
    func frontLeaseKeepsActivity(_ ending: CallEnding, withClicks: Bool) async throws {
        let broker = SeatBroker()
        let idle = IdleClock()
        var handingBack = false
        var finishHandback: CheckedContinuation<Void, Never>?
        let handback: @MainActor () async -> FrontLeaseOutcome = {
            handingBack = true
            await withCheckedContinuation { finishHandback = $0 }
            return .completed(afterMilliseconds: 1)
        }
        let desktop = Self.frontSession(
            broker,
            idle: idle,
            lending: { _, _, _, body in
                await body()
                return await handback()
            },
            clickLending: { _, _, _, body in
                await body(LeaseClicks().clicks)
                return await handback()
            }
        )
        try await desktop.turn {
            _ = try await desktop.open(
                application: "Test",
                window     : nil
            )
            let id = desktop.id
            await Self.until { idle.pendingCount == 1 }
            var inBody = false
            var finishBody: CheckedContinuation<Void, Never>?
            let call = Task {
                await Self.borrowFront(
                    desktop,
                    withClicks: withClicks
                ) {
                    inBody = true
                    await withCheckedContinuation { finishBody = $0 }
                    try Task.checkCancellation()
                    if ending == .failure { throw Opened() }
                    return 17
                }
            }
            await Self.until { inBody }
            #expect(inBody)
            await idle.elapseOldest()
            await Self.letTheWaitBegin()
            #expect(desktop.id == id)
            #expect(desktop.holdsComputer)
            #expect(idle.waits == [.seconds(30)])
            if ending == .cancellation { call.cancel() }
            finishBody?.resume()
            await Self.until { handingBack }
            #expect(handingBack)
            await Self.letTheWaitBegin()
            #expect(desktop.id == id)
            #expect(idle.waits == [.seconds(30)])
            finishHandback?.resume()
            let answer = await call.value
            let result = try #require(answer.result)
            switch ending {
                case .success: #expect(try result.get() == 17)
                case .failure: #expect(throws: Opened.self) { try result.get() }
                case .cancellation: #expect(throws: CancellationError.self) { try result.get() }
            }
            await Self.until { idle.pendingCount == 1 }
            #expect(idle.waits == [.seconds(30), .seconds(30)])
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(desktop.id == nil)
            #expect(broker.queue.entries.isEmpty)
        }
        await desktop.close()
    }


    /// A session whose open succeeds without a display. The seating names the Dock as the running
    /// application, which nothing adopts or quits, and the scene is supplied in place of perception.
    /// `idle` supplies the idle window's clock, and `holding` a pid the granted session holds as if
    /// adopted, so closing finishes with it as the broker's ledger says.
    private static func seated(
        _ broker  : SeatBroker,
        idleWindow: Duration = BrokeredAutomationSession.idleWindow,
        idle      : IdleClock? = nil,
        holding   : pid_t? = nil,
        opens     : @escaping @MainActor () -> Void = {}
    ) throws -> BrokeredAutomationSession {
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let waitIdle: BrokeredAutomationSession.IdleWaiting = if let idle {
            { await idle.wait($0) }
        } else {
            { try await Task.sleep(for: $0) }
        }
        return session(broker, perceiving: { _, _ in scene }, idleWindow: idleWindow, waitIdle: waitIdle) {
            session, _, _ in
            opens()
            if let holding { session.holdWithoutAdopting(holding, name: "Test") }
            return (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
                    SeatTarget())
        }
    }

    /// Waits, a few milliseconds at a time and for at most two seconds, until `condition` holds.
    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Long enough for a task about to suspend on the queue to get there.
    private static func letTheWaitBegin() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test("human cancellation preserves the opened session and a later observation", arguments: [false, true])
    func interruptibleSceneKeepsSession(opening: Bool) async throws {
        let broker = SeatBroker()
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        var block = opening
        var reading = false
        var cancelled = false
        let desktop = Self.session(broker, perceiving: { _, _ in
            if block {
                reading = true
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError { cancelled = true; throw CancellationError() }
            }
            return scene
        }, running: { _ in RunningFixture() }) { _, _, _ in
            (TargetApp(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "test.process",
                       name: "Test", bundleURL: nil, windows: []), SeatTarget())
        }
        if !opening { _ = try await desktop.open(application: "Test", window: nil) }
        block = true
        let interruption = AutomationCallInterruption()
        let tools = AutomationTools(session: desktop)
        let call = Task {
            try await AutomationCallInterruption.$current.withValue(interruption) {
                if opening { return try await tools.call("open_session", .object(["app": .string("Test")])) }
                return try await tools.call("observe", .object([
                    "session": .string(try #require(desktop.id).uuidString)
                ]))
            }
        }
        await Self.until { reading }
        #expect(reading)
        #expect(interruption.isReadingOpeningScene == opening)
        let id = try #require(desktop.id)
        interruption.interruptForHumanControl()
        call.cancel()
        if opening {
            let answer = try await call.value
            let text = try #require(answer["content"].array?.first?["text"].string)
            #expect(text.contains(id.uuidString))
            #expect(text.contains("The person took control"))
            #expect(!text.contains("\"scene\":"))
        } else {
            await #expect(throws: CancellationError.self) { try await call.value }
        }
        #expect(cancelled)
        #expect(desktop.id == id)
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.count == 1)
        block = false
        #expect(try await desktop.observe().windowTitle == "Test")
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the open holds the seat while it runs, a failed open gives it back, and a double close is nothing")
    func theSeatIsHeldForTheOpenAndGivenBackWhenItFails() async throws {
        let broker = SeatBroker()
        var during: [SeatQueue.Entry] = []
        var granted: AgentSession?
        let desktop = Self.session(broker) { session, _, _ in
            during  = broker.queue.entries
            granted = session
            throw Opened()
        }

        await #expect(throws: Opened.self) { try await desktop.open(application: "Calculator", window: nil) }

        #expect(during.map(\.label) == [Self.label])
        #expect(during.map(\.state) == [.acting])
        #expect(broker.queue.entries.isEmpty)
        #expect(desktop.id == nil)
        #expect(desktop.activity == nil)
        await desktop.close()
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)

        // Given back open, so the queue parks it warm and hands the same seat to the next entry.
        let next = try await broker.queue.acquire("next")
        #expect(next.session === granted)
        #expect(next.session.isOpen)
        next.giveBack()
    }

    @Test("the broker's own opening refuses an unknown name, and the seat goes back")
    func theBrokersOpeningRefusesAnUnknownNameAndGivesTheSeatBack() async throws {
        let broker  = SeatBroker()
        let desktop = Self.session(broker, seating: BrokeredAutomationSession.seatedByTheBroker)

        let refusal = await #expect(throws: SeatBrokerError.self) {
            try await desktop.open(application: "No Such Application 5f0c", window: nil)
        }
        guard case .applicationNotResolved? = refusal else {
            Issue.record("expected applicationNotResolved, got \(String(describing: refusal))")
            return
        }
        #expect(broker.queue.entries.isEmpty)
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a first scene that fails after the borrow closes it, and the seat goes back")
    func aFirstSceneThatFailsClosesAndGivesTheSeatBack() async throws {
        let broker = SeatBroker()
        let target = SeatTarget()
        let desktop = Self.session(broker) { _, _, _ in
            (TargetApp(pid: getpid(), bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), target)
        }

        // The target has no seat, so perception refuses; the Brain is flushed and the target stopped.
        await #expect(throws: (any Error).self) { try await desktop.open(application: "Test", window: nil) }

        #expect(broker.queue.entries.isEmpty)
        #expect(desktop.id == nil)
        #expect(throws: SeatDrivingFailure.notAdopted) { try target.agentSeat() }
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a lost assignment closes the worker session and gives its lease back")
    func aLostAssignmentEndsTheWorkerSession() async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let target = SeatTarget()
        var observations = 0
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(broker, perceiving: { _, _ in
            observations += 1
            guard observations == 1 else { throw ObservationUnavailable.notAssigned }
            return scene
        }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), target)
        }
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(desktop.id != nil)

        do {
            _ = try await desktop.observe()
            Issue.record("An absent assignment cannot return a scene")
        } catch {
            #expect(error is AutomationFailure)
            let message = String(describing: error)
            #expect(message.contains("session ended"))
            #expect(message.contains("Use status"))
            #expect(message.contains("current windows"))
        }

        #expect(desktop.id == nil)
        #expect(desktop.activity == nil)
        #expect(!desktop.holdsComputer)
        #expect(!desktop.hasScreen)
        #expect(broker.queue.entries.isEmpty)
        #expect(throws: SeatDrivingFailure.notAdopted) { try target.agentSeat() }
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the session answers the bundle id of the application it holds, and none before open or after close")
    func answersTheHeldBundleID() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(desktop.memoryApplication == nil)
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(desktop.memoryApplication == "com.apple.dock")
        await desktop.close()
        #expect(desktop.memoryApplication == nil)
    }

    @Test("the session records the app it holds for every session's adapters, and forgets it on close")
    func recordsItsHold() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(SeatHolds.bundleID(heldBy: desktop.holdKey) == nil)
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(SeatHolds.bundleID(heldBy: desktop.holdKey) == "com.apple.dock")
        #expect(SeatHolds.bundleIDs.contains("com.apple.dock"))
        await desktop.close()
        #expect(SeatHolds.bundleID(heldBy: desktop.holdKey) == nil)
    }

    @Test("opening another window of the held app keeps the lease and session, including on refusal")
    func anotherWindowKeepsTheSeat() async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        var title = "Edit"
        var openings = 0
        var switches: [String] = []
        let desktop = BrokeredAutomationSession(
            broker: broker, workerID: UUID(), knowledgeDirectory: Scratch.directory("braus-switch"),
            allowsDestructive: false, missingGrant: { nil }, requestGrants: {},
            seating: { _, _, _ in
                openings += 1
                return (TargetApp(pid: dock, bundleID: "com.apple.dock", name: "Dock", bundleURL: nil, windows: []), SeatTarget())
            },
            perceiving: { _, _ in
                SceneSnapshot(bundleID: "com.apple.dock", appName: "Dock", windowTitle: title,
                              viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
            },
            switching: { _, _, wanted in
                switches.append(wanted)
                if wanted == "Missing" { throw Opened() }
                title = wanted
            },
            stoppedForGood: { _ in false }
        )
        _ = try await desktop.open(application: "com.apple.dock", window: "Edit")
        let originalID = desktop.id
        let entries = broker.queue.entries
        let mix = try await desktop.open(application: "com.apple.dock", window: "Mix")
        #expect(mix.windowTitle == "Mix")
        await #expect(throws: Opened.self) {
            try await desktop.open(application: "com.apple.dock", window: "Missing")
        }
        #expect(switches == ["Mix", "Missing"])
        #expect(openings == 1)
        #expect(desktop.id == originalID)
        #expect(broker.queue.entries == entries)
        await desktop.close()
    }

    @Test("an open over a seat that stopped for good ends that session and opens the requested one")
    func anOpenReplacesAStoppedSeat() async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        var seatings = 0
        var stopped  = false
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : UUID(),
            knowledgeDirectory: Scratch.directory("braus-brokered"),
            allowsDestructive : false,
            resolving         : Self.resolvedForTheFixtures,
            missingGrant      : { nil },
            requestGrants     : {},
            seating           : { _, _, _ in
                seatings += 1
                return (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []),
                        SeatTarget())
            },
            perceiving        : { _, _ in scene },
            stoppedForGood    : { _ in stopped }
        )
        _ = try await desktop.open(application: "Test", window: nil)
        let first = try #require(desktop.id)

        // A live seat still refuses a second open.
        await #expect(throws: AutomationFailure.self) { try await desktop.open(application: "Test", window: nil) }
        #expect(desktop.id == first)

        stopped = true
        _ = try await desktop.open(application: "Test", window: nil)
        #expect(seatings == 2, "the dead session was closed and the requested one opened")
        #expect(desktop.id != nil && desktop.id != first)
        stopped = false
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a recoverable observation refusal preserves the current worker session", arguments: [
        ObservationUnavailable.noSelectedTarget,
        .suspended([.noEligibleTarget]),
        .captureDeadlineExpired(attemptsSpent: 1),
        .captureFailed(reason: "controlled transient capture failure")
    ])
    func anObservationRefusalKeepsTheWorkerSession(_ failure: ObservationUnavailable) async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        var observations = 0
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(broker, perceiving: { _, _ in
            observations += 1
            guard observations != 2 else { throw failure }
            return scene
        }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), SeatTarget())
        }
        _ = try await desktop.open(application: "Test", window: nil)
        let identity = try #require(desktop.id)

        await #expect(throws: AutomationFailure.self) { try await desktop.observe() }

        #expect(desktop.id == identity)
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.count == 1)
        _ = try await desktop.observe()
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an idempotent close preserves cleanup warnings without retrying the quit request")
    func aSecondCloseKeepsTheCleanupWarning() async throws {
        let owned: pid_t = 900_003
        var asked: [pid_t] = []
        let ledger = LaunchLedger(terminate: { asked.append($0) }, isTerminated: { _ in false })
        ledger.record(.openedByAgent, for: owned)
        let broker = SeatBroker(configuration: .init(), ledger: ledger)
        let desktop = try Self.seated(broker, holding: owned)
        _ = try await desktop.open(application: "Test", window: nil)

        await desktop.close()
        let warning = try #require(desktop.closeWarning)
        #expect(warning.contains("still running after the quit request"))
        await desktop.close()

        #expect(desktop.closeWarning == warning)
        #expect(asked == [owned])
        #expect(desktop.id == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a late observation cannot affect a newer worker session", arguments: [true, false])
    func anOldObservationCannotAffectTheNewSession(_ losesAssignment: Bool) async throws {
        let broker = SeatBroker()
        let dock = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier)
        var observations = 0
        var resumeOldObservation: CheckedContinuation<Void, Never>?
        let scene = SceneSnapshot(bundleID: "test.process", appName: "Test", windowTitle: "Test",
                                  viewportPixelSize: ViewportPixelSize(width: 10, height: 10), elements: [])
        let desktop = Self.session(broker, perceiving: { _, _ in
            observations += 1
            if observations == 2 {
                await withCheckedContinuation { resumeOldObservation = $0 }
                if losesAssignment { throw ObservationUnavailable.notAssigned }
            }
            return scene
        }) { _, _, _ in
            (TargetApp(pid: dock, bundleID: "test.process", name: "Test", bundleURL: nil, windows: []), SeatTarget())
        }
        _ = try await desktop.open(application: "Test", window: nil)
        let oldObservation = Task { try await desktop.observe() }
        await Self.until { resumeOldObservation != nil }
        let continuation = try #require(resumeOldObservation)
        await desktop.close()
        _ = try await desktop.open(application: "Test", window: nil)
        let newIdentity = try #require(desktop.id)

        continuation.resume()
        await #expect(throws: AutomationFailure.self) { try await oldObservation.value }

        #expect(desktop.id == newIdentity)
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.count == 1)
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a turn stopped while its open waits for the computer leaves the queue")
    func aStoppedTurnWaitingForTheComputerLeavesTheQueue() async throws {
        let broker = SeatBroker()
        let holder = try await broker.queue.acquire("holder")
        var wasSeated = false
        let desktop = Self.session(broker) { _, _, _ in
            wasSeated = true
            throw Opened()
        }
        // The host's stop is `MCPRouter.pause`, which cancels the tool call in flight.
        let tools  = AutomationTools(session: desktop)
        let router = MCPRouter(tools: AutomationTools.definitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        let call = Task {
            await router.handle(.object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params" : .object(["name": .string("open_session"),
                                    "arguments": .object(["app": .string("Calculator")])])
            ]))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !broker.queue.entries.contains(where: { $0.label == Self.label }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(broker.queue.entries.map(\.label) == ["holder", Self.label])
        #expect(desktop.activity == "Waiting for the computer (1 ahead)")

        router.pause()
        let reply = await call.value
        await router.drain()

        #expect(reply?["result"]["isError"] == .bool(true))
        #expect(broker.queue.entries.map(\.label) == ["holder"])
        #expect(desktop.activity == nil)
        #expect(!wasSeated)
        await desktop.close()
        holder.giveBack()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a missing grant is asked for and refused by name, before the queue")
    func aMissingGrantRefusesByNameBeforeTheQueue() async throws {
        let names: [PermissionKind: String] = [
            .screenRecording: "Screen Recording", .accessibility: "Accessibility",
            .postEvent: "Keyboard and Mouse Control"
        ]
        for (kind, name) in names {
            let broker = SeatBroker()
            var requests = 0
            var wasSeated = false
            let desktop = Self.session(broker, missing: kind, requests: { requests += 1 }) { _, _, _ in
                wasSeated = true
                throw Opened()
            }
            let refusal = await #expect(throws: AutomationFailure.self) {
                try await desktop.open(application: "Calculator", window: nil)
            }
            #expect(refusal?.description.contains("macOS \(name) permission") == true)
            #expect(refusal?.description.contains("System Settings > Privacy & Security") == true)
            #expect(requests == 1)
            #expect(!wasSeated)
            #expect(broker.queue.entries.isEmpty)
        }
    }

    @Test("a missing grant names who to allow: Braus by default, the terminal the command line passes",
          arguments: ["Braus", "the terminal launching Braus"])
    func aMissingGrantNamesTheGrantee(_ grantee: String) async throws {
        let desktop = Self.session(SeatBroker(), grantee: grantee, missing: .screenRecording) { _, _, _ in
            throw Opened()
        }
        let refusal = await #expect(throws: AutomationFailure.self) {
            try await desktop.open(application: "Calculator", window: nil)
        }
        let sentence = refusal?.description ?? ""
        #expect(sentence.contains("allow \(grantee) in System Settings > Privacy & Security"))
        #expect(sentence.contains("then quit and reopen \(grantee)."))
        if grantee != "Braus" { #expect(!sentence.contains("allow Braus in"), "the terminal is the grantee") }
    }

    @Test("a launch that shows no window refuses with the reason, and the seat goes back")
    func aLaunchThatShowsNoWindowRefusesWithTheReason() async throws {
        let broker  = SeatBroker()
        let desktop = Self.session(broker) { _, _, _ in
            throw SeatBrokerError.noWindowShown(application: "TextEdit", seconds: 20, wasLaunched: true,
                                                wasQuit: true)
        }

        let refusal = await #expect(throws: AutomationFailure.self) {
            try await desktop.open(application: "TextEdit", window: nil)
        }

        let sentence = refusal?.description ?? ""
        #expect(sentence.hasPrefix("TextEdit was launched in the background and showed no window within 20 s."))
        #expect(sentence.contains("the seat never brings an application to the front"))
        #expect(sentence.contains("the computer was given back"))
        #expect(sentence.contains("TextEdit was closed again, since this open had launched it."))
        #expect(!sentence.contains("still running"))
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an application that was never seated says whether it was closed again or left running")
    func anUnseatedApplicationSaysWhatBecameOfIt() {
        func sentence(_ wasLaunched: Bool, _ wasQuit: Bool) -> String {
            let error = SeatBrokerError.noWindowShown(application: "Notes", seconds: 20, wasLaunched: wasLaunched,
                                                      wasQuit: wasQuit)
            return String(describing: BrokeredAutomationSession.refusal(for: error))
        }
        #expect(sentence(false, false).hasPrefix("Notes is running and showed no window within 20 s."))
        #expect(sentence(false, false).contains("Notes was left running, since it was already open."))
        #expect(sentence(true, false).contains("Notes could not be closed again and is still running"))
        #expect(SeatBrokerError.noWindowShown(application: "Notes", seconds: 20, wasLaunched: true, wasQuit: true)
            .localizedDescription == "Notes launched but showed no window within 20 s. "
                + "Notes was closed again, since this open had launched it.")
    }

    @Test("a seat that cannot observe is worded for the agent, not printed as its case")
    func aSeatThatCannotObserveIsWorded() {
        let refusal = BrokeredAutomationSession.refusal(for: ObservationUnavailable.suspended([.noEligibleTarget]))
        #expect(refusal is AutomationFailure)
        #expect(String(describing: refusal) == "The seat cannot observe while suspended: "
            + "no window of the assigned application is eligible to act in.")
    }

    @Test("a different opening window is refused with its numbers and without exposing its scene")
    func anOpeningIdentityMismatchIsWorded() {
        let process = ProcessIdentity(processID: 4242, serialNumberHigh: 1, serialNumberLow: 4242)
        let expected = WindowIdentity(process: process, windowNumber: 777, ownerConnectionID: 5242)
        let observed = WindowIdentity(process: process, windowNumber: 778, ownerConnectionID: 5242)
        let refusal = BrokeredAutomationSession.refusal(for: SeatDrivingFailure.initialWindowChanged(
            expected: expected,
            observed: observed
        ))
        #expect(refusal is AutomationFailure)
        #expect(String(describing: refusal).contains("adopted identity of window 777"))
        #expect(String(describing: refusal).contains("reported window: 778"))
        #expect(String(describing: refusal).contains("No scene from that window was returned and no input was sent"))
    }

    /// What `open` answers when its first observation fails with `failure`, the seating naming the
    /// Dock as the running application and `dialog` read as the one it has open.
    private static func openRefusal(
        _ failure: @escaping @MainActor (ProcessIdentity) -> any Error,
        dialog   : DialogButtonPress.OpenDialog
    ) async throws -> (message: String, holds: Bool) {
        let dock = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        )
        let process = ProcessIdentity(
            processID       : dock,
            serialNumberHigh: 1,
            serialNumberLow : 1
        )
        let desktop = Self.session(
            SeatBroker(),
            perceiving: { _, _ in throw failure(process) },
            dialog    : dialog
        ) { _, _, _ in
            let opened = TargetApp(
                pid      : dock,
                bundleID : "test.process",
                name     : "Test",
                bundleURL: nil,
                windows  : []
            )
            return (opened, SeatTarget())
        }
        do {
            try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        } catch {
            return (String(describing: error), desktop.holdsComputer)
        }
        Issue.record("the open succeeded")
        return ("", desktop.holdsComputer)
    }

    static let newDocument = DialogButtonPress.OpenDialog(
        title   : "New Document",
        role    : "dialog",
        buttons : ["Close", "Cancel"],
        isListed: true
    )

    @Test("an open blocked by a dialog names it, its buttons and how to close it, and gives the seat back")
    func anOpenBlockedByADialogNamesIt() async throws {
        let refused = try await Self.openRefusal(
            { process in
                SeatDrivingFailure.initialWindowChanged(
                    expected: WindowIdentity(process: process, windowNumber: 777, ownerConnectionID: 1),
                    observed: WindowIdentity(process: process, windowNumber: 778, ownerConnectionID: 1)
                )
            },
            dialog: Self.newDocument
        )
        #expect(refused.message.contains("adopted identity of window 777"))
        #expect(refused.message.contains(
            "has the dialog \"New Document\" open, which blocks the window the session adopted. "
                + "Its buttons: Close, Cancel."
        ))
        #expect(refused.message.contains(
            "open_session on Dock with window \"New Document\", press \"Cancel\", then close_session"
        ))
        #expect(!refused.holds)
    }

    @Test("an open that fails for another reason does not blame an open dialog")
    func anOpenFailingOtherwiseNamesNoDialog() async throws {
        let refused = try await Self.openRefusal(
            { _ in ObservationUnavailable.suspended([.noEligibleTarget]) },
            dialog: Self.newDocument
        )
        #expect(refused.message.hasPrefix("The seat cannot observe while suspended"))
        #expect(!refused.message.contains("New Document"))
        #expect(!refused.holds)
    }

    @Test("a dialog with no readable buttons is closed with Escape, never in DaVinci Resolve")
    func aBlockingDialogWithoutButtons() {
        let dialog = DialogButtonPress.OpenDialog(
            title   : "New Project",
            role    : "dialog",
            buttons : [],
            isListed: true
        )
        let photoshop = BrokeredAutomationSession.blocking(
            dialog,
            application: "Photoshop",
            bundleID   : "com.adobe.Photoshop"
        )
        #expect(photoshop.contains("Accessibility cannot read its buttons."))
        #expect(photoshop.contains("with window \"New Project\", press_key escape, then close_session"))
        let resolve = BrokeredAutomationSession.blocking(
            dialog,
            application: "DaVinci Resolve",
            bundleID   : "com.blackmagic-design.DaVinciResolve"
        )
        #expect(!resolve.lowercased().contains("escape"))
        #expect(resolve.hasSuffix("Ask the person to close it, then open DaVinci Resolve again."))
    }

    @Test("a dialog the window list does not offer is left to the person, with the way to close it")
    func anUnlistedDialogIsLeftToThePerson() {
        let untitled = BrokeredAutomationSession.blocking(
            DialogButtonPress.OpenDialog(
                title   : "",
                role    : "sheet",
                buttons : ["OK"],
                isListed: false
            ),
            application: "Notes",
            bundleID   : nil
        )
        #expect(untitled.hasPrefix("Notes has an untitled sheet open"))
        #expect(untitled.hasSuffix("Ask the person to close it with one of its buttons, then open Notes again."))
        let modeless = BrokeredAutomationSession.blocking(
            DialogButtonPress.OpenDialog(
                title   : "Find",
                role    : "dialog",
                buttons : ["Cancel", "Next"],
                isListed: false
            ),
            application: "Notes",
            bundleID   : nil
        )
        #expect(!modeless.contains("open_session"))
        #expect(modeless.hasSuffix("Ask the person to close it with its \"Cancel\" button, then open Notes again."))
    }

    @Test("a holder idle between turns gives the seat back as soon as another entry waits",
          .timeLimit(.minutes(1)))
    func anIdleHolderReleasesWhenAnEntryStartsWaiting() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        #expect(desktop.activity == "Using Test")

        let waiter = Task { try await broker.queue.acquire("Braus") }
        let lease  = try await waiter.value

        #expect(desktop.activity == nil)
        #expect(desktop.id == nil)
        #expect(broker.queue.entries.map(\.label) == ["Braus"])
        // The next turn's tools find no session, and the sentence leads the agent to open_session again.
        let refusal = await #expect(throws: AutomationFailure.self) { try await desktop.observe() }
        #expect(refusal?.description == "No live application session. Use windows and open_session, then observe.")
        lease.giveBack()
    }

    @Test("a holder in a turn keeps the seat while the turn runs and gives it back as the turn ends",
          .timeLimit(.minutes(1)))
    func aHolderInATurnReleasesAtTheTurnsEndAndNotBefore() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        var waiter: Task<SeatLease, any Error>?
        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            waiter = Task { try await broker.queue.acquire("Braus") }
            await Self.letTheWaitBegin()
            #expect(broker.queue.entries.map(\.state) == [.acting, .waiting])
            #expect(desktop.activity == "Using Test")
            #expect(try await desktop.observe().appName == "Test")
        }
        #expect(desktop.activity == nil)
        let lease = try #require(try await waiter?.value)
        #expect(broker.queue.entries.map(\.label) == ["Braus"])
        lease.giveBack()
    }

    @Test("the computer can be released only while the session holds it, not while it waits",
          .timeLimit(.minutes(1)))
    func releasingIsOfferedOnlyWhileTheSeatIsHeld() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(!desktop.holdsComputer)

        let holder = try await broker.queue.acquire("holder")
        let open   = Task { try await desktop.open(application: "Test", window: nil) }
        await Self.letTheWaitBegin()
        #expect(desktop.activity == "Waiting for the computer (1 ahead)")
        #expect(!desktop.holdsComputer)

        holder.giveBack()
        _ = try await open.value
        #expect(desktop.holdsComputer)

        // What the toolbar's Release the computer calls: the lease goes back, the session stays usable.
        await desktop.close()
        #expect(!desktop.holdsComputer)
        #expect(desktop.activity == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the screen can be watched only while an application is open on the held seat",
          .timeLimit(.minutes(1)))
    func theScreenIsThereOnlyWhileTheSeatIsHeld() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(!desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) == nil)

        let holder = try await broker.queue.acquire("holder")
        let open   = Task { try await desktop.open(application: "Test", window: nil) }
        await Self.letTheWaitBegin()
        #expect(!desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) == nil, "waiting is not watching")

        holder.giveBack()
        _ = try await open.value
        #expect(desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) != nil)

        // Given back, the seat goes warm to the next entry, so no new view may reach it.
        await desktop.close()
        #expect(!desktop.hasScreen && desktop.makeScreenView(contentsScale: 2) == nil)
        #expect(desktop.screenFrame == .zero)
    }

    @Test("a turn's seat line names the live session, and once it is released the application it had",
          .timeLimit(.minutes(1)))
    func theTurnStatusNamesTheLiveSessionOrTheLastApplication() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        #expect(desktop.turnStatus == "Braus seat: no session is open.")

        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let id   = try #require(desktop.id)
        var live = ""
        try await desktop.turn { live = desktop.turnStatus }
        #expect(live == "Braus seat: session \(id.uuidString) is open on Test (test.process), window \"Test\". "
            + "Observe it with this session ID before acting.")

        // Only the current turn's final wait may release; earlier cancelled waits do nothing.
        await idle.elapseAll()
        await Self.until { !desktop.holdsComputer }
        #expect(desktop.id == nil)
        #expect(desktop.turnStatus == "Braus seat: no session is open. "
            + "The last one was on Test (test.process), window \"Test\".")
    }

    @Test("a worker alone keeps the seat across its turns")
    func aLoneHolderKeepsTheSeatAcrossTurns() async throws {
        let broker  = SeatBroker()
        let desktop = try Self.seated(broker)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        await Self.letTheWaitBegin()
        try await desktop.turn { _ = try await desktop.observe() }
        await Self.letTheWaitBegin()

        #expect(desktop.activity == "Using Test")
        #expect(desktop.id != nil)
        #expect(broker.queue.entries.map(\.label) == [Self.label])
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the queue entry carries the worker's id, so two workers with one name each read their own place")
    func theQueueLabelIsTheWorkersIDAndTheRowReadsItsOwnPosition() async throws {
        let broker = SeatBroker()
        let holder = try await broker.queue.acquire("Braus")
        let first  = UUID()
        let second = UUID()
        let one = Self.session(broker, workerID: first) { _, _, _ in throw Opened() }
        let two = Self.session(broker, workerID: second) { _, _, _ in throw Opened() }
        let early = Task { try await one.open(application: "Calculator", window: nil) }
        await Self.letTheWaitBegin()
        let later = Task { try await two.open(application: "Calculator", window: nil) }
        await Self.letTheWaitBegin()

        #expect(broker.queue.entries.map(\.label) == ["Braus", first.uuidString, second.uuidString])
        #expect(one.activity == "Waiting for the computer (1 ahead)")
        #expect(two.activity == "Waiting for the computer (2 ahead)")

        early.cancel()
        later.cancel()
        _ = await (early.result, later.result)
        holder.giveBack()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("the waiting line's position is the entry's own index in the queue, and never a guess")
    func theWaitingLineIsReadFromTheQueueEntries() {
        func entry(_ label: String, _ state: SeatQueue.State) -> SeatQueue.Entry {
            SeatQueue.Entry(id: UUID(), label: label, state: state, since: Date())
        }
        let line = BrokeredAutomationSession.waiting

        #expect(line(Self.label, [entry("holder", .acting), entry("Rizzo", .waiting), entry(Self.label, .waiting)])
            == "Waiting for the computer (2 ahead)")
        #expect(line(Self.label, [entry("holder", .acting), entry(Self.label, .waiting)])
            == "Waiting for the computer (1 ahead)")
        // Two waiting entries under one label, or none, cannot say which is this worker's.
        #expect(line(Self.label, [entry("holder", .acting), entry(Self.label, .waiting), entry(Self.label, .waiting)])
            == "Waiting for the computer")
        #expect(line(Self.label, [entry("holder", .acting)]) == "Waiting for the computer")
        #expect(line(Self.label, [entry(Self.label, .acting)]) == "Waiting for the computer")
    }

    @Test("a holder idle after its turn gives the computer back once the idle window elapses",
          .timeLimit(.minutes(1)))
    func anIdleHolderReleasesWhenTheIdleWindowElapses() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            await Self.until { idle.pendingCount == 1 }
        }
        #expect(desktop.activity == "Using Test")

        await Self.until { idle.pendingCount == 2 }
        #expect(idle.waits == [.seconds(30), .seconds(30)])
        // Ending the turn starts a full pause, even if its in-turn wait returns late.
        await idle.elapseOldest()
        await Self.letTheWaitBegin()
        #expect(desktop.holdsComputer)
        await idle.elapseOldest()
        await Self.until { !desktop.holdsComputer }

        #expect(!desktop.holdsComputer)
        #expect(desktop.activity == nil)
        #expect(desktop.id == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a follow-up inside the idle window cancels the release and reuses the open session",
          .timeLimit(.minutes(1)))
    func aFollowUpInsideTheIdleWindowReusesTheSession() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        var opens   = 0
        let desktop = try Self.seated(broker, idleWindow: .milliseconds(50), idle: idle, opens: { opens += 1 })
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let session = desktop.id
        await Self.until { idle.pendingCount == 1 }
        #expect(idle.waits == [.milliseconds(50)])

        try await desktop.turn {
            // The first window elapses inside the follow-up, which cancelled it: nothing is released.
            await idle.elapseOldest()
            await Self.letTheWaitBegin()
            #expect(desktop.holdsComputer)
            let scene = try await desktop.observe()
            #expect(scene.appName == "Test")
        }
        #expect(opens == 1)
        #expect(desktop.id == session)
        #expect(desktop.activity == "Using Test")
        await Self.letTheWaitBegin()
        #expect(idle.pendingCount >= 1)
        #expect(idle.waits.allSatisfy { $0 == .milliseconds(50) })

        await idle.elapseAll()
        await Self.until { !desktop.holdsComputer }
        #expect(desktop.activity == nil)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an entry that starts waiting during the idle window is given the computer at once",
          .timeLimit(.minutes(1)))
    func aWaiterDuringTheIdleWindowReleasesAtOnce() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        await Self.until { idle.pendingCount == 1 }

        let lease = try await Task { try await broker.queue.acquire("Braus") }.value

        #expect(!desktop.holdsComputer)
        #expect(broker.queue.entries.map(\.label) == ["Braus"])

        // The window elapsing after the queue's release closes nothing: the other entry keeps the seat.
        await idle.elapseAll()
        await Self.letTheWaitBegin()
        #expect(broker.queue.entries.map(\.label) == ["Braus"])
        #expect(broker.queue.entries.map(\.state) == [.acting])
        #expect(lease.session.isOpen)
        lease.giveBack()
    }

    @Test("an inactive application is released inside its turn and the next call finds no session",
          .timeLimit(.minutes(1)))
    func anInactiveHolderReleasesInsideItsTurn() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)

        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            #expect(desktop.holdsComputer)
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(idle.waits == [.seconds(30)])
            #expect(desktop.id == nil)
            #expect(broker.queue.entries.isEmpty)
            let refusal = await #expect(throws: AutomationFailure.self) { try await desktop.observe() }
            #expect(refusal?.description == "No live application session. Use windows and open_session, then observe.")
        }
        #expect(desktop.activity == nil)
        #expect(broker.queue.entries.isEmpty)
        await desktop.close()
    }

    enum CallEnding: CaseIterable, Sendable {
        case success
        case failure
        case cancellation
    }

    @Test("overlapping activity tokens keep the application until the last call ends")
    func activityTokensKeepTheSeatUntilTheLastCallEnds() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            await Self.until { idle.pendingCount == 1 }
            let first = desktop.beginActivity()
            let last  = desktop.beginActivity()
            desktop.endActivity(first)
            desktop.endActivity(first)
            await idle.elapseOldest()
            await Self.letTheWaitBegin()
            #expect(desktop.holdsComputer)
            #expect(idle.waits == [.seconds(30)])

            desktop.endActivity(last)
            await Self.until { idle.pendingCount == 1 }
            // A duplicate end must not replace the newly started idle window.
            desktop.endActivity(last)
            await Self.letTheWaitBegin()
            #expect(idle.waits == [.seconds(30), .seconds(30)])
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(desktop.id == nil)
            #expect(broker.queue.entries.isEmpty)
        }
        await desktop.close()
    }

    @Test("the tools' hold opens the application through the broker and keeps it until the command returns",
          .timeLimit(.minutes(1)))
    func toolsHoldKeepsTheApplicationThroughTheCommand() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = Self.frontSession(broker, idle: idle)
        let tools   = AutomationTools(session: desktop)
        try await desktop.turn {
            let held = try await tools.holding("test.process") { hold in
                await Self.letTheWaitBegin()
                #expect(idle.pendingCount == 0, "no inactivity release waits under the command")
                #expect(hold == .held)
                return desktop.memoryApplication
            }
            #expect(held == "test.process" && desktop.holdsComputer)
            #expect(desktop.hasSeat && desktop.holdsOnSeat)
            await Self.until { idle.pendingCount == 1 }
            #expect(idle.waits == [.seconds(30)], "the idle window starts once the command returns")

            var ran = false
            let refused = await #expect(throws: AutomationTools.HoldRefused.self) {
                try await tools.holding("test.other") { _ in ran = true }
            }
            #expect(refused?.reason.contains("could not hold test.other") == true, "\(String(describing: refused))")
            #expect(!ran && desktop.id == nil, "the held application was closed first, and nothing ran")
            #expect(desktop.hasSeat && !desktop.holdsOnSeat)
        }
        await desktop.close()
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("an observation in flight prevents release and starts a full idle window on every exit",
          arguments: CallEnding.allCases)
    func anObservationInFlightRestartsTheIdleClock(_ ending: CallEnding) async throws {
        let broker = SeatBroker()
        let idle   = IdleClock()
        let scene  = SceneSnapshot(
            bundleID         : "test.process",
            appName          : "Test",
            windowTitle      : "Test",
            viewportPixelSize: ViewportPixelSize(
                width : 10,
                height: 10
            ),
            elements         : []
        )
        var blocks = false
        var reading = false
        var finishReading: CheckedContinuation<Void, Never>?
        let desktop = Self.session(
            broker,
            perceiving: { _, _ in
                if blocks {
                    reading = true
                    await withCheckedContinuation { finishReading = $0 }
                    try Task.checkCancellation()
                    if ending == .failure { throw Opened() }
                }
                return scene
            },
            running: { _ in RunningFixture() },
            waitIdle: { await idle.wait($0) }
        ) { _, _, _ in
            let opened = TargetApp(
                pid      : ProcessInfo.processInfo.processIdentifier,
                bundleID : "test.process",
                name     : "Test",
                bundleURL: nil,
                windows  : []
            )
            return (opened, SeatTarget())
        }

        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            let session = desktop.id
            await Self.until { idle.pendingCount == 1 }
            blocks = true
            let call = Task { try await desktop.observe() }
            await Self.until { reading }
            #expect(reading)

            await idle.elapseOldest()
            await Self.letTheWaitBegin()
            #expect(desktop.id == session)
            #expect(desktop.holdsComputer)
            #expect(idle.waits == [.seconds(30)])

            if ending == .cancellation { call.cancel() }
            finishReading?.resume()
            switch ending {
                case .success:
                    #expect(try await call.value.windowTitle == "Test")
                case .failure:
                    await #expect(throws: Opened.self) { try await call.value }
                case .cancellation:
                    await #expect(throws: CancellationError.self) { try await call.value }
            }
            await Self.until { idle.pendingCount == 1 }
            #expect(idle.waits == [.seconds(30), .seconds(30)])
            #expect(desktop.id == session)
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(desktop.id == nil)
            #expect(broker.queue.entries.isEmpty)
        }
        await desktop.close()
    }

    @Test("human intervention prevents inactivity release inside a turn and its end restores the clock")
    func humanControlStopsTheInTurnIdleClock() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            let session = desktop.id
            await Self.until { idle.pendingCount == 1 }
            let hold = try desktop.retainForHumanIntervention()
            _ = try await desktop.observe()
            await idle.elapseOldest()
            await Self.letTheWaitBegin()
            #expect(desktop.id == session)
            #expect(desktop.holdsComputer)
            #expect(idle.waits == [.seconds(30)])

            try await desktop.endHumanIntervention(hold)
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(idle.waits == [.seconds(30), .seconds(30)])
            #expect(desktop.id == nil)
            #expect(broker.queue.entries.isEmpty)
        }
        await desktop.close()
    }

    @Test("after Release the computer, the pending idle release does nothing, even under a later lease",
          .timeLimit(.minutes(1)))
    func aStaleIdleReleaseAfterAManualReleaseDoesNothing() async throws {
        let broker  = SeatBroker()
        let idle    = IdleClock()
        var opens   = 0
        let desktop = try Self.seated(broker, idle: idle, opens: { opens += 1 })
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        await Self.until { idle.pendingCount == 1 }

        await desktop.close()
        #expect(!desktop.holdsComputer)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        #expect(opens == 2)
        await Self.until { idle.pendingCount == 2 }
        #expect(idle.pendingCount == 2)

        // The first wait belonged to the lease given back by hand.
        await idle.elapseOldest()
        await Self.letTheWaitBegin()
        #expect(desktop.holdsComputer)
        #expect(broker.queue.entries.map(\.label) == [Self.label])

        await idle.elapseOldest()
        await Self.until { !desktop.holdsComputer }
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("human control retains a lease across the turn boundary and a queued worker")
    func humanControlKeepsTheLeaseUntilExplicitlyEnded() async throws {
        let broker = SeatBroker()
        let desktop = try Self.seated(broker)
        var hold: UUID?
        try await desktop.turn {
            _ = try await desktop.open(application: "Test", window: nil)
            hold = try desktop.retainForHumanIntervention()
        }
        let id = desktop.id
        let waiter = Task { try await broker.queue.acquire("next worker") }
        await Self.letTheWaitBegin()
        #expect(broker.queue.entries.map(\.state) == [.acting, .waiting])
        #expect(desktop.id == id)
        try await desktop.endHumanIntervention(try #require(hold))
        let next = try await waiter.value
        #expect(desktop.id == nil)
        next.giveBack()
    }

    @Test("a cancelled idle timer cannot release human control; ending restores idle release")
    func humanControlOutlivesAnOldIdleTimer() async throws {
        let broker = SeatBroker()
        let idle = IdleClock()
        let desktop = try Self.seated(broker, idle: idle)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        await Self.until { idle.pendingCount == 1 }
        let hold = try desktop.retainForHumanIntervention()
        #expect(try desktop.retainForHumanIntervention() == hold)
        await idle.elapseOldest()
        await Self.letTheWaitBegin()
        #expect(desktop.holdsComputer)
        try await desktop.endHumanIntervention(hold)
        await idle.elapseOldest()
        await Self.until { !desktop.holdsComputer }
        #expect(desktop.id == nil)
    }

    @Test("close overrides human retention and an old token cannot end a later intervention")
    func closingInvalidatesHumanRetention() async throws {
        let broker = SeatBroker()
        let desktop = try Self.seated(broker)
        #expect(throws: AutomationFailure.self) { try desktop.retainForHumanIntervention() }
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let old = try desktop.retainForHumanIntervention()
        await desktop.close()
        #expect(!desktop.holdsComputer)
        try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
        let current = try desktop.retainForHumanIntervention()
        #expect(current != old)
        await #expect(throws: AutomationFailure.self) { try await desktop.endHumanIntervention(old) }
        #expect(desktop.holdsComputer)
        try await desktop.endHumanIntervention(current)
        await desktop.close()
    }

    @Test("the idle release quits an application the agent launched and leaves one already running",
          .timeLimit(.minutes(1)))
    func theIdleReleaseFinishesWithTheApplicationAsItsProvenanceSays() async throws {
        let launched: pid_t = 900_001
        let found   : pid_t = 900_002
        var asked: [pid_t] = []
        let ledger = LaunchLedger { asked.append($0) }
        ledger.record(.openedByAgent, for: launched)
        let broker = SeatBroker(configuration: .init(), ledger: ledger)

        for pid in [launched, found] {
            let idle    = IdleClock()
            let desktop = try Self.seated(broker, idle: idle, holding: pid)
            try await desktop.turn { _ = try await desktop.open(application: "Test", window: nil) }
            // Nothing is finished with while the window has not elapsed.
            #expect(asked == (pid == launched ? [] : [launched]))
            await idle.elapseOldest()
            await Self.until { !desktop.holdsComputer }
            #expect(!desktop.holdsComputer)
        }

        #expect(asked == [launched])
        #expect(ledger.provenance(of: launched) == .alreadyRunning)
        #expect(broker.queue.entries.isEmpty)
    }

    @Test("a moment in front is read again only when the item read enabled, and a refusal says why")
    func menuRefreshReadsTheSeatsAnswer() {
        #expect(BrokeredAutomationSession.refresh(after: .ready(afterMilliseconds: 1050)) == .readAgain)
        #expect(BrokeredAutomationSession.refresh(after: .notReady(afterMilliseconds: 2000))
            == .stillDisabled(reason: nil), "the disabled refusal stands as it is")
        guard case .stillDisabled(let elsewhere?) = BrokeredAutomationSession.refresh(after: .frontElsewhere(afterMilliseconds: 822)),
              elsewhere.contains("another application came to the front") else {
            Issue.record("a front taken during the moment was not explained"); return
        }
        #expect(BrokeredAutomationSession.refresh(after: .refused(.noUserWindow)) == .stillDisabled(
            reason: "It could not be brought forward for a moment, because no window of the person's own "
                + "is in front to come back to."
        ))
        #expect(BrokeredAutomationSession.refresh(after: .refused(.dialogOpen)) == .blockedByDialog,
                "an open dialog gets its own refusal, not the stale-menu one")
        guard case .stillDisabled(.some) = BrokeredAutomationSession.refresh(after: .handbackNotVerified) else {
            Issue.record("an unverified handback was not explained"); return
        }
    }

    @Test("apps keeps the ranking's order and names the folder only where two share a name")
    func appsNameTheFolderOnlyWhereTwoShareAName() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let apps = [
            TargetApp(pid: 7, bundleID: "com.avid.ProTools", name: "Pro Tools",
                      bundleURL: URL(fileURLWithPath: "/Applications/Pro Tools.app"), windows: [],
                      version: "26.4.1.179"),
            TargetApp(pid: nil, bundleID: "com.example.ProTools", name: "Pro Tools",
                      bundleURL: home.appending(path: "Applications/Pro Tools.app"), windows: []),
            TargetApp(pid: nil, bundleID: "com.avid.ProToolsDeveloper", name: "Pro Tools Developer",
                      bundleURL: URL(fileURLWithPath: "/Applications/Pro Tools Developer.app"), windows: []),
        ]
        #expect(BrokeredAutomationSession.candidates(apps, defaultBrowser: nil) == [
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.avid.ProTools", version: "26.4.1.179",
                                 isRunning: true, location: "/Applications"),
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.example.ProTools", version: nil,
                                 isRunning: false, location: "~/Applications"),
            ApplicationCandidate(name: "Pro Tools Developer", bundleID: "com.avid.ProToolsDeveloper", version: nil,
                                 isRunning: false),
        ])
    }

    @Test("apps marks the application that opens web links by default, and no other")
    func appsMarksOnlyTheDefaultBrowser() {
        let apps = [
            TargetApp(pid: 7, bundleID: "com.example.Browser", name: "Browser", bundleURL: nil, windows: []),
            TargetApp(pid: nil, bundleID: "com.example.Other", name: "Other Browser", bundleURL: nil, windows: []),
            TargetApp(pid: 9, bundleID: "", name: "Helper", bundleURL: nil, windows: []),
        ]
        let marked = BrokeredAutomationSession.candidates(apps, defaultBrowser: "com.example.Browser")
        #expect(marked.map(\.isDefaultBrowser) == [true, false, false])
        #expect(BrokeredAutomationSession.candidates(apps, defaultBrowser: nil).allSatisfy { !$0.isDefaultBrowser })
        #expect(BrokeredAutomationSession.candidates(apps, defaultBrowser: "").allSatisfy { !$0.isDefaultBrowser },
                "an application with no bundle ID is nobody's browser")
    }

    @Test("W1: a text the call withholds reaches the Seat's engine as withheld; a binding the Seat cannot keep is refused, nothing typed")
    func withheldTextReachesTheEngine() async throws {
        let input = InputRequest.Input.typeText("Withheld-Sentinel-90", into: "Nome", replacing: true)
        let withheld = BrokeredAutomationSession.request(input, section: "form", application: .current, withholdsText: true)
        #expect(withheld.withholdsText && withheld.input == input && withheld.section == "form" && withheld.binding == nil)
        #expect(!BrokeredAutomationSession.request(input, section: nil, application: .current, withholdsText: false).withholdsText)
        let session = Self.session(SeatBroker()) { _, _, _ in throw Opened() }
        let binding = TextTargetBinding(identity: TargetIdentity("double|nome"), role: "AXTextField", label: "Nome")
        await #expect(throws: AutomationFailure.self) {
            _ = try await session.deliver(input, section: nil, dispatch: .bound(binding))
        }
    }
}
