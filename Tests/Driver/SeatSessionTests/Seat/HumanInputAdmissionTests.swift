import Foundation
import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Human episode pause")
struct HumanInputAdmissionTests {

    @Test("a human episode pauses agent Commands without admitting another source")
    func episodePausesAgentCommands() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)
        let token = try context.seat.beginHumanInput()
        await #expect(throws: InputFailure.inputPaused([.humanIntervention])) {
            try await context.seat.send(ObservationAdmissionTests.click,
                observation: observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
    }

    @Test("intentional activation requires verified focus before handback")
    func intentionalActivation() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing)
        let token = try context.seat.beginHumanInput()
        sensing.frontmostProcessID = FakeGeometry.targetPID
        #expect(context.seat.allowsHumanActivation(processID: FakeGeometry.targetPID))
        await #expect(throws: InputFailure.inputPaused([.recoveryUnavailable])) {
            try await context.seat.endHumanInput(token)
        }
        #expect(context.seat.inputPauseReasons == [.humanIntervention])
        sensing.frontmostProcessID = 99
        try await context.seat.endHumanInput(token)
        #expect(!context.seat.allowsHumanActivation(processID: FakeGeometry.targetPID))
    }

    @Test("a pending seat command cannot revive after a complete human episode")
    func waitingSeatCommandKeepsItsOriginalAuthority() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)
        context.sender.onSendWait = {
            let token = try? context.sender.gate.beginHumanInput()
            if let token { try? await context.sender.gate.endHumanInput(token) }
        }
        await #expect(throws: InputFailure.inputPaused([.inputAuthorityExpired])) {
            try await context.seat.send(
                ObservationAdmissionTests.click,
                observation: observation,
                turn: turn
            )
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("human admission cannot clear a stop or use an observation from before handback")
    func handbackInvalidatesObservation() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        let observation = try await observedReference(context.seat)
        try await context.seat.endHumanInput(token)
        await #expect(throws: ObservationAdmissionRefusal.noCurrentObservation(.requestedByConsumer)) {
            try await context.seat.send(
                ObservationAdmissionTests.click,
                observation: observation,
                turn: turn
            )
        }
        #expect(context.sender.sent.isEmpty)
        context.seat.stopAdmittingCommands()
        #expect(throws: InputFailure.inputPaused([.deliberateStop])) {
            try context.seat.beginHumanInput()
        }
        try context.seat.release(turn)
    }

    @Test("takeover refuses while an agent's split key command is in flight")
    func splitAgentKeyKeepsItsReleaseOwner() async throws {
        let sensing = FakeSensing()
        let sender = FakeSender()
        let endpoints = EndpointDiscovery(
            pointer: { _, _, _, _ in .failure(.noNodeAtPoint) },
            keyboardContext: { _, chain, generation in
                let now = DispatchTime.now().uptimeNanoseconds
                guard let window = sensing.windowGeometry(of: chain.surface.windowNumber),
                      let geometry = sensing.windowGeometryObservation(of: window),
                      let endpoint = ResolvedInputEndpoint(
                        kind: .keyboardContext,
                        geometry: geometry,
                        evidence: .attestedSurfaceItself,
                        relation: .logicalSurface,
                        logicalSurface: chain.surface,
                        accessibilityProcessID: chain.surface.processID,
                        selectionGeneration: generation,
                        resolvedAtNanoseconds: now,
                        expiresAtNanoseconds: now + 500_000_000,
                        focusedNodeWindowNumber: chain.surface.windowNumber
                      ) else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
                return .success(endpoint)
            },
            identity: { sensing.windowGeometry(of: $0)?.identity },
            focusedWindowNumber: { _ in FakeGeometry.windowNumber },
            focusedWindowReading: { _, _ in .window(FakeGeometry.windowNumber) }
        )
        let seat = makeSeat(sensing: sensing, sender: sender, marker: 99_301, endpoints: endpoints)
        _ = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let context = (seat: seat, sender: sender)
        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)
        context.sender.onSendWait = {
            #expect(throws: InputFailure.nativeTextInputRefused(.contextActive)) {
                try context.seat.beginHumanInput()
            }
        }
        let receipt = try await context.seat.send(
            .key(virtualKey: 0, text: "", phase: .down),
            observation: observation,
            turn: turn
        )
        #expect(context.sender.sent.count == 1)
        #expect(context.seat.inputPauseReasons.isEmpty)
        try context.seat.confirm(receipt, .observed)
        try context.seat.release(turn)
    }

    @Test("handback stays blocked until fresh focus verification; renewed takeover invalidates handback",
          arguments: [false, true])
    func handbackBoundary(newInput: Bool) async throws {
        let sensing = FakeSensing()
        let user = FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame,
            processID: FakeGeometry.userPID, windowNumber: 8801)
        sensing.additionalWindows[user.windowNumber] = user
        sensing.focusedUserWindow = user
        sensing.frontmostProcessID = user.processID
        let context = try await ObservationAdmissionTests.composed(sensing: sensing)
        let snapshot = FocusRecoverySnapshot(topologyIsValid: true,
            virtualBounds: FakeGeometry.virtual, physicalBounds: [FakeGeometry.physical],
            windows: [user, context.window.reference])
        sensing.focusRecoverySnapshot = snapshot
        var requests = 0
        let recovery = UserFocusRecovery(sensing: sensing, gate: context.sender.gate,
            adopted: { [context.window.reference] },
            restore: { _ in requests += 1; return 0 },
            allowsHumanActivation: { context.seat.allowsHumanActivation(processID: $0) },
            changed: { _ in })
        context.seat.focusRecovery = recovery
        defer { recovery.stop() }
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        sensing.frontmostProcessID = FakeGeometry.targetPID
        sensing.snapshotPreparation = {
            if newInput { _ = try? context.seat.beginHumanInput() }
            return snapshot
        }
        if newInput {
            await #expect(throws: InputFailure.inputPaused([.inputAuthorityExpired])) {
                try await context.seat.endHumanInput(token)
            }
            #expect(requests == 0)
            #expect(context.seat.inputPauseReasons.contains(.humanIntervention))
            sensing.frontmostProcessID = user.processID
            try await context.seat.endHumanInput(token)
        } else {
            try await context.seat.endHumanInput(token)
            #expect(requests == 1)
            #expect(context.seat.inputPauseReasons == [.focusRecovery])
            sensing.frontmostProcessID = user.processID
            recovery.verify()
            recovery.verify()
            #expect(context.seat.inputPauseReasons.isEmpty)
        }
        try context.seat.release(turn)
    }

    @Test("takeover closes agent admission before reading the user's focus")
    func gateBeforeFocusRead() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing)
        let recovery = UserFocusRecovery(sensing: sensing, gate: context.sender.gate,
            adopted: { [context.window.reference] }, restore: { _ in 0 }, changed: { _ in })
        context.seat.focusRecovery = recovery
        defer { recovery.stop() }
        let turn = try await context.seat.acquire()
        var reads = 0
        sensing.onUserWindowRead = {
            reads += 1
            #expect(context.sender.gate.pauseReasons.contains(.humanIntervention))
        }
        let token = try context.seat.beginHumanInput()
        sensing.onUserWindowRead = nil
        #expect(reads > 0)
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
    }

    @Test("assignment release abandons a refused human episode before the next agent Command")
    func releaseAbandonsRefusedEpisode() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)
        let receipt = try await context.seat.send(ObservationAdmissionTests.click,
            observation: observation, turn: turn)
        let token = try context.seat.beginHumanInput()
        await #expect(throws: SessionFailure.unconfirmedCommands(count: 1)) {
            try await context.seat.endHumanInput(token)
        }
        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
        _ = await context.seat.releaseAssignment()
        #expect(!context.sender.gate.isCurrentHumanInput(token))
        #expect(!context.seat.inputPauseReasons.contains(.humanIntervention))
        #expect(!context.seat.coherentState.hasCurrentObservation)
        try context.sender.gate.check()
    }

    @Test("teardown abandons the human episode before returning windows")
    func teardownAbandonsHumanEpisode() async throws {
        let context = try await ObservationAdmissionTests.composed()
        _ = try context.seat.beginHumanInput()
        _ = await context.seat.releaseAllWindows(.returnToUserSeat)
        #expect(context.sender.gate.pauseReasons.contains(.deliberateStop))
        #expect(!context.sender.gate.pauseReasons.contains(.humanIntervention))
    }

    @Test("ending a lease clears a failed handback and preserves other pauses")
    func abandonEpisode() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing)
        let token = try context.seat.beginHumanInput()
        sensing.frontmostProcessID = FakeGeometry.targetPID
        await #expect(throws: InputFailure.inputPaused([.recoveryUnavailable])) {
            try await context.seat.endHumanInput(token)
        }
        context.sender.gate.pause(.windowTransfer)
        await context.seat.abandonHumanInput(reason: .leaseEnded)
        #expect(!context.seat.hasHumanInput)
        #expect(!context.sender.gate.isCurrentHumanInput(token))
        #expect(context.seat.inputPauseReasons == [.windowTransfer])
        context.sender.gate.resume(.windowTransfer)
        try context.sender.gate.check()
    }

    @Test("assignment release clears a gate-only episode even with no assigned application")
    func releaseWithoutAssignmentClearsStaleGate() async throws {
        let sender = FakeSender()
        let seat = makeSeat(sender: sender)
        let token = try sender.gate.beginHumanInput()
        _ = await seat.releaseAssignment()
        #expect(!seat.hasHumanInput)
        #expect(!sender.gate.isCurrentHumanInput(token))
        try sender.gate.check()
    }

    @Test("concurrent and cancelled closure callers clear the human episode")
    func abandonmentIsIdempotentAfterCancellation() async throws {
        let sender = FakeSender()
        let seat = makeSeat(sender: sender)
        _ = try seat.beginHumanInput()
        let first = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await seat.abandonHumanInput(reason: .leaseEnded)
            #expect(!seat.hasHumanInput)
        }
        let second = Task {
            await seat.abandonHumanInput(reason: .sessionClosed)
            #expect(!seat.hasHumanInput)
        }
        await first.value
        await second.value
        try sender.gate.check()
    }
}
