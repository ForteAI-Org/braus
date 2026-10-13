import CoreGraphics
import Foundation
import InteractionObservation
import Testing

/// Opt-in read-only coverage of the actual AX adapter on a configured desktop point.
@Suite @MainActor
struct InteractionObservationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAUS_INTERACTION_LIVE_AX"] == "1"))
    func configuredNativeName() throws {
        let env = ProcessInfo.processInfo.environment
        let pid = try #require(env["BRAUS_INTERACTION_AX_PID"].flatMap(Int32.init))
        let x = try #require(env["BRAUS_INTERACTION_AX_X"].flatMap(Double.init))
        let y = try #require(env["BRAUS_INTERACTION_AX_Y"].flatMap(Double.init))
        let expected = try #require(env["BRAUS_INTERACTION_AX_LABEL"])
        let source = try #require(env["BRAUS_INTERACTION_AX_SOURCE"])
        let result = InteractionSceneReader.accessibility(at: CGPoint(x: x, y: y), processID: pid)
        #expect(result.status == "read_after_event")
        #expect(result.label == expected)
        #expect(result.labelSource == source)
        #expect(result.processID == pid)
    }
}
