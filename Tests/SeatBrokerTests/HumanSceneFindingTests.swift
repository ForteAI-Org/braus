import Foundation
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanSceneFindingTests {
    @Test func partialFinalReadKeepsTheAvailableWindowEvidence() throws {
        let initial = SceneSnapshot(bundleID: "test", appName: "Editor", windowTitle: "Document",
            viewportPixelSize: .init(width: 800, height: 600), elements: [])
        var final = initial
        final.elements.append(.init(id: "created", kind: .control, label: "Created",
            bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXRow"))
        let finding = try HumanSceneFinding(sequence: 0, kind: .failed, text: "", readMilliseconds: 1,
            reason: .read, scenes: [7: final], initialScenes: [7: initial])
        let decoded = try finding.sceneEvidence()
        #expect(finding.reason == .read)
        #expect(decoded.scenes[7] == final)
        let evidence = HumanInterventionEvidence(findings: [], finalState: finding)
        // A row that only appeared in view is no effect: nothing certifies it was created.
        #expect(evidence.ledger.effects.isEmpty)
        #expect(evidence.ledger.dispositions.contains { if case .noise = $0 { true } else { false } })
        #expect(evidence.notice == nil)
        #expect(!HumanInterventionSummary.digest(evidence).text.contains("surface unavailable"))
    }

    @Test func completelyFailedFinalReadKeepsItsWarning() {
        let finding = HumanSceneFinding(sequence: 0, kind: .failed, reason: .read)
        let evidence = HumanInterventionEvidence(findings: [], finalState: finding)
        #expect(evidence.notice != nil)
        #expect(HumanInterventionSummary.digest(evidence).text == "No changes made.")
    }
}
