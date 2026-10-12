//
//  KeyboardBoundaryReadTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import ApplicationServices
import Dispatch
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The focus reading at the posting boundary of an ordinary window's keys.
///
/// The boundary reads through the shipping resolver over a fake application
/// whose accessibility answers only requests allowed at least `answerSeconds`,
/// and `-25204` to the others, as a busy application does. Resolution itself
/// is a fake: what is on trial is how many times the boundary asks, and what
/// a slow, a moved and an absent focus are read as.
@MainActor
@Suite("Reading the focus at the boundary of an ordinary window's keys")
struct KeyboardBoundaryReadTests {

    @MainActor
    final class Application {

        /// The shortest accessibility timeout the application answers within.
        var answerSeconds: Float = 0

        /// The window the focused control names, `nil` for no focused control.
        var focusedWindow: Int? = FakeGeometry.windowNumber

        /// When set, a recovery attempt answers only once the endpoint expired.
        var answersRecoveryAfterExpiry = false

        /// How long a resolved endpoint lives.
        var lifetimeNanoseconds: UInt64 = 500_000_000

        /// Every reading of the focus: the resolution and each boundary.
        var focusReadings = 0

        var afterResolving: (() -> Void)?

        private var expiresAt: UInt64 = 0

        private func answer(_ timeout: Float, _ value: Int?) -> (AXError, Int?) {
            if answersRecoveryAfterExpiry, timeout > BoundedAccessibilityRead.fastTimeout {
                while DispatchTime.now().uptimeNanoseconds <= expiresAt + 20_000_000 {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return (.success, value)
            }
            guard timeout >= answerSeconds else { return (.cannotComplete, nil) }
            return value.map { (.success, $0) } ?? (.noValue, nil)
        }

        /// The shipping resolver's two boundary readings over this application.
        /// The plain one reads at the fixed fast timeout, as the shipping one does.
        private var resolver: DialogEndpointResolver<Int> {
            DialogEndpointResolver<Int>(
                nodeAtPoint  : { _ in nil },
                focusedNode  : { [self] in answer(BoundedAccessibilityRead.fastTimeout, focusedWindow).1 },
                children     : { _ in .leaf },
                nodeFrame    : { _ in nil },
                nodeWindow   : { [self] in answer(BoundedAccessibilityRead.fastTimeout, $0).1 },
                nodeProcess  : { _ in nil },
                identity     : { _ in nil },
                geometry     : { _, _ in nil },
                focusAttempt : { [self] in answer($0, focusedWindow) },
                windowAttempt: { [self] node, timeout in answer(timeout, node) }
            )
        }

        func discovery(sensing: FakeSensing) -> EndpointDiscovery {
            EndpointDiscovery(
                pointer: { _, _, _, _ in .failure(.noNodeAtPoint) },
                keyboardContext: { [self] _, chain, generation in
                    focusReadings += 1
                    let now = DispatchTime.now().uptimeNanoseconds
                    expiresAt = now + lifetimeNanoseconds
                    defer { afterResolving?() }
                    guard let window = sensing.windowGeometry(of: chain.surface.windowNumber),
                          let geometry = sensing.windowGeometryObservation(of: window),
                          let endpoint = ResolvedInputEndpoint(
                            kind                   : .keyboardContext,
                            geometry               : geometry,
                            evidence               : .attestedSurfaceItself,
                            relation               : .logicalSurface,
                            logicalSurface         : chain.surface,
                            accessibilityProcessID : chain.surface.processID,
                            selectionGeneration    : generation,
                            resolvedAtNanoseconds  : now,
                            expiresAtNanoseconds   : expiresAt,
                            focusedNodeWindowNumber: chain.surface.windowNumber
                          ) else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                    return .success(endpoint)
                },
                identity: { sensing.windowGeometry(of: $0)?.identity },
                focusedWindowNumber: { [self] _ in
                    focusReadings += 1
                    return resolver.focusedNodeWindowNumber()
                },
                focusedWindowReading: { [self] _, deadline in
                    focusReadings += 1
                    return resolver.focusedNodeWindowReading(deadlineNanoseconds: deadline)
                }
            )
        }
    }

    struct Context {
        let seat       : AgentSeat
        let sender     : FakeSender
        let application: Application
        let window     : AdoptedWindow
        let observation: SeatObservationReference
    }

    static let escape = InputCommand.key(virtualKey: 53, text: "")

    private func context(
        platform: any InputPlatform = QtPlatform(),
        modal   : Bool = false
    ) async throws -> Context {
        let sensing     = FakeSensing()
        let sender      = FakeSender()
        let reader      = ControlledSurfaceReader(sensing: sensing)
        let application = Application()
        sensing.geometry = FakeGeometry.reference(frame: FakeGeometry.adoptedWindow.frame)
        let seat = makeSeat(
            sensing  : sensing,
            sender   : sender,
            reader   : reader,
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: application.discovery(sensing: sensing)
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: platform
        )
        if modal {
            reader.roles[window.id]  = .dialog
            reader.modals[window.id] = .application
            seat.refreshTargetReadings()
            seat.refreshTargetReadings()
        }
        return Context(
            seat       : seat,
            sender     : sender,
            application: application,
            window     : window,
            observation: try await observedReference(seat)
        )
    }

    private func send(
        _ command: InputCommand = Self.escape,
        in context: Context,
        platform  : (any InputPlatform)? = nil
    ) async throws {
        let turn = try await context.seat.acquire()
        defer { try? context.seat.release(turn) }
        let receipt = try await context.seat.send(
            command,
            observation: context.observation,
            turn       : turn,
            platform   : platform
        )
        try context.seat.confirm(receipt, .unknown)
    }

    // MARK: A busy application

    @Test("a focus that answers only on the recovery attempt still takes the key")
    func aSlowFocusIsReadWithinTheDeadline() async throws {
        let context = try await context()
        context.application.answerSeconds = 0.2

        try await send(in: context)

        #expect(context.sender.sent.count == 1)
    }

    @Test("an application that never answers refuses as an unreadable focus, posting nothing")
    func aFocusThatNeverAnswersIsNotReadable() async throws {
        let context = try await context()
        context.application.answerSeconds = .infinity

        await #expect(throws: InputEndpointInvalidation.focusNotReadable) {
            try await send(in: context)
        }
        #expect(context.sender.sent.isEmpty)
    }

    @Test("a recovery that answers after the endpoint expired retires it as expired")
    func aLateRecoveryExpiresTheEndpoint() async throws {
        let context = try await context()
        context.application.answerSeconds = 0.2
        context.application.lifetimeNanoseconds = 150_000_000
        context.application.answersRecoveryAfterExpiry = true

        await #expect(throws: InputEndpointInvalidation.expired) {
            try await send(in: context)
        }
        #expect(context.sender.sent.isEmpty)
    }

    @Test("a modal surface whose focus never answers keeps the moved-focus refusal")
    func aModalSurfaceKeepsItsOwnBoundary() async throws {
        let context = try await context(modal: true)
        context.application.answerSeconds = .infinity

        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await send(in: context)
        }
        #expect(context.sender.sent.isEmpty)
    }

    // MARK: How many times the focus is read

    @Test(
        "an ordinary window's unprepared key reads the focus at its resolution and before the post",
        arguments: ["Qt", "AppKit"]
    )
    func anUnpreparedKeyReadsTheFocusTwice(family: String) async throws {
        let context = try await context(platform: family == "Qt" ? QtPlatform() : AppKitPlatform())

        try await send(in: context)

        #expect(context.sender.sent.count == 1)
        #expect(context.application.focusReadings == 2)
    }

    @Test("a prepared, a primed or a modal key keeps both boundary readings", arguments: [0, 1, 2])
    func aPreparedPrimedOrModalKeyReadsAtBothBoundaries(row: Int) async throws {
        let context = try await context(
            platform: row == 0 ? ChromiumPlatform() : QtPlatform(),
            modal   : row == 2
        )
        let command: InputCommand = row == 0 ? .insertText("a") : Self.escape
        let platform: (any InputPlatform)? = row == 1
            ? UXPPlatform().primingKeys(in: context.window.reference)
            : nil

        try await send(command, in: context, platform: platform)

        #expect(context.sender.sent.count == 1)
        #expect(context.application.focusReadings == 3)
    }

    // MARK: A focus that moved or went away

    @Test("a focus in another window or in none retires the key, posting nothing", arguments: [9_011, nil])
    func aMovedOrAbsentFocusRetiresTheKey(window: Int?) async throws {
        let context = try await context()
        context.application.afterResolving = { context.application.focusedWindow = window }

        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await send(in: context)
        }
        #expect(context.sender.sent.isEmpty)
    }

    @Test("a focus that moved while the gate waited retires the key, posting nothing")
    func aFocusMovedDuringTheGateWaitRetiresTheKey() async throws {
        let context = try await context()
        context.sender.onSendWait = { context.application.focusedWindow = 9_011 }

        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await send(in: context)
        }
        #expect(context.sender.sent.isEmpty)
    }
}
