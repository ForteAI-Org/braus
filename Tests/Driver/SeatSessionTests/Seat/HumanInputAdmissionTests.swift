import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

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
        try context.seat.endHumanInput(token)
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
        try context.seat.endHumanInput(token)
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
        try context.seat.endHumanInput(token)
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

}
