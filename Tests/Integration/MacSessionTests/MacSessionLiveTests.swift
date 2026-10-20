import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
@testable import MacSession
import PerceptionCore
import Router
import Testing

/// The wiring on the real Mac. BRAUS_MAC_LIVE_TESTS=1, the desktop free: `open_session` through the
/// router opens Calculator on the MacDriver in the background, 7 × 6 = is pressed through the engine, and
/// the display reads 42. The person's front app stays in front. Calculator is quit only when the test
/// launched it. Its key labels are those of an Italian Mac.
@MainActor
@Suite("Mac session, live", .serialized)
struct MacSessionLiveTests {

    @Test("Calculator through the router and the MacDriver: 7 × 6 = 42, the person's app kept in front",
          .enabled(if: ProcessInfo.processInfo.environment["BRAUS_MAC_LIVE_TESTS"] == "1"))
    func calculator() async throws {
        let bundleID = "com.apple.calculator"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("mac-live-\(UUID().uuidString)")
        let routing = RoutingAutomationSession(native: MacAutomationSession(knowledgeDirectory: knowledge),
                                               desktop: SessionStub(handoff: nil))
        let tools = AutomationTools(session: routing)
        defer {
            if !wasRunning {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        _ = try await tools.call("open_session", .object(["app": .string("Calculator")]))
        print("open_session: \(clock.now - started), handoff: \(routing.lastHandoff.map(\.reason) ?? "none")")
        try #require(routing.lastHandoff == nil, "the MacDriver took Calculator")
        #expect(routing.memoryApplication == bundleID)

        for key in ["Cancella tutto", "7", "Moltiplica", "6", "Uguale"] {
            let pressed = clock.now
            let outcome = try await routing.act(target: key, verb: .click, section: nil, desiredState: nil)
            print("\(key): \(outcome.kind.rawValue) in \(clock.now - pressed): \(outcome.message.prefix(120))")
            if key != "Cancella tutto" { #expect(outcome.kind == .foundActed, "\(key): \(outcome.message)") }
        }
        let scene = try await routing.observe()
        let texts = scene.elements.filter { $0.kind == .text }.map(\.label)
        print("display: \(texts)")
        #expect(texts.contains { $0.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
            .map(String.init).joined() == "42" })
        #expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == front, "the person's app stayed in front")
        await routing.close()
    }
}
