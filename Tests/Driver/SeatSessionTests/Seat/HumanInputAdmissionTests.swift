import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
private final class ProgressiveHumanSender: FakeSender, HumanPointerSending, @unchecked Sendable {
    var phases: [HumanPointerGesture.Phase] = []
    var onFragment: (@MainActor @Sendable (HumanPointerGesture.Phase, Bool) async throws -> Void)?

    func sendHumanPointer(
        _ gesture: HumanPointerGesture, to window: WindowReference, correlationID: Int64,
        platform: any InputPlatform, token: InputCommandGate.HumanInput,
        beforeFirstPost: @escaping @Sendable () async throws -> Void,
        beforeContinuation: @escaping @Sendable () async throws -> Void
    ) async throws -> InputReceipt {
        try await gate.withHumanInput(token) {
            try await beforeFirstPost()
            try await gesture.consume { phase, _, _, cleanup in
                if !cleanup {
                    if phase != .down { try await beforeContinuation() }
                    try gate.check()
                }
                await MainActor.run { phases.append(phase) }
                try await onFragment?(phase, cleanup)
            }
            return InputReceipt(eventCount: await MainActor.run { phases.count },
                route: InputRoute(poster: .publicProcess, routedEventCount: 3,
                    windowNumber: window.windowNumber, ownerConnectionID: try #require(window.identity).ownerConnectionID))
        }
    }
}

@MainActor
@Suite("Human input admission")
struct HumanInputAdmissionTests {
    @Test("human authority admits a complete command while ordinary input stays blocked")
    func humanCommandRetainsObservationChecks() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        #expect(context.seat.inputPauseReasons == [.humanIntervention])
        let observation = try await observedReference(context.seat)
        await #expect(throws: InputFailure.inputPaused([.humanIntervention])) {
            try await context.seat.send(
                ObservationAdmissionTests.click,
                observation: observation,
                turn: turn
            )
        }
        let receipt = try await context.seat.sendHumanInput(
            ObservationAdmissionTests.click,
            observation: observation,
            turn: turn,
            token: token
        )
        #expect(context.sender.sent.count == 1)
        #expect(!context.seat.coherentState.hasCurrentObservation)
        try context.seat.confirm(receipt, .observed)
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
        #expect(context.seat.inputPauseReasons.isEmpty)
    }

    @Test("a pending seat command cannot revive after a complete human episode")
    func waitingSeatCommandKeepsItsOriginalAuthority() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let observation = try await observedReference(context.seat)
        context.sender.onSendWait = {
            let token = try? context.sender.gate.beginHumanInput()
            if let token { try? context.sender.gate.endHumanInput(token) }
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

    @Test("a human cannot leave a split key gesture held")
    func splitHumanKeyRefusesWithoutPosting() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        let observation = try await observedReference(context.seat)
        await #expect(throws: InputFailure.nativeTextInputRefused(.commandUnsupported)) {
            try await context.seat.sendHumanInput(
                .key(virtualKey: 0, text: "", phase: .down),
                observation: observation,
                turn: turn,
                token: token
            )
        }
        #expect(context.sender.sent.isEmpty)
        try await context.seat.endHumanInput(token)
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

    @Test("intentional activation is allowed only during human ownership")
    func intentionalActivation() async throws {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing)
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        sensing.frontmostProcessID = FakeGeometry.targetPID
        let observation = try await observedReference(context.seat)
        let receipt = try await context.seat.sendHumanInput(ObservationAdmissionTests.click,
            observation: observation, turn: turn, token: token)
        try context.seat.confirm(receipt, .observed)
        // Without a qualified focus restorer, handback must wait for the person.
        await #expect(throws: InputFailure.inputPaused([.recoveryUnavailable])) {
            try await context.seat.endHumanInput(token)
        }
        #expect(context.seat.inputPauseReasons == [.humanIntervention])
        sensing.frontmostProcessID = 99
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
    }

    @Test("progressive input is refused by a sender without that capability")
    func unsupportedProgressiveSender() async throws {
        let context = try await ObservationAdmissionTests.composed()
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        let observation = try await observedReference(context.seat)
        guard case .click(let point, _, _) = ObservationAdmissionTests.click else { return }
        let gesture = HumanPointerGesture(at: point)
        await #expect(throws: HumanPointerGesture.Refusal.unsupported) {
            try await context.seat.sendHumanPointer(gesture, observation: observation, turn: turn, token: token)
        }
        #expect(context.sender.sent.isEmpty)
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
    }

    @Test("a progressive gesture holds the seat boundary until up")
    func progressiveSeatBoundary() async throws {
        let sender = ProgressiveHumanSender()
        let context = try await ObservationAdmissionTests.composed(sender: sender)
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        let observation = try await observedReference(context.seat)
        guard case .click(let point, _, _) = ObservationAdmissionTests.click else { return }
        let gesture = HumanPointerGesture(at: point)
        sender.onFragment = { phase, _ in
            if phase == .down {
                await #expect(throws: SessionFailure.assignmentStillInUse(.commandInFlight)) {
                    try await context.seat.endHumanInput(token)
                }
                try gesture.move(to: point)
                try gesture.release(at: point)
            }
        }
        let receipt = try await context.seat.sendHumanPointer(gesture,
            observation: observation, turn: turn, token: token)
        #expect(sender.phases == [.down, .dragged, .up])
        #expect(!context.seat.coherentState.hasCurrentObservation)
        try context.seat.confirm(receipt, .observed)
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
    }

    @Test("a common fault stops movement but permits release of the human press")
    func progressiveFaultCleanup() async throws {
        let sender = ProgressiveHumanSender()
        let context = try await ObservationAdmissionTests.composed(sender: sender)
        let turn = try await context.seat.acquire()
        let token = try context.seat.beginHumanInput()
        let observation = try await observedReference(context.seat)
        guard case .click(let point, _, _) = ObservationAdmissionTests.click else { return }
        let gesture = HumanPointerGesture(at: point)
        sender.onFragment = { phase, cleanup in
            if phase == .down {
                sender.gate.pause(.windowTransfer)
                try gesture.move(to: point)
            }
            if phase == .up { #expect(cleanup) }
        }
        await #expect(throws: HumanPointerFailure.self) {
            try await context.seat.sendHumanPointer(gesture,
                observation: observation, turn: turn, token: token)
        }
        #expect(sender.phases == [.down, .up])
        #expect(!context.seat.coherentState.hasCurrentObservation)
        #expect(context.seat.inputPauseReasons.contains(.windowTransfer))
        sender.gate.resume(.windowTransfer)
        try await context.seat.endHumanInput(token)
        try context.seat.release(turn)
    }

    @Test("handback stays blocked until fresh focus verification; new input invalidates preparation",
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

}
