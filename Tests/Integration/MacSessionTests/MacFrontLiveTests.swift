import AppKit
import AutomationRuntime
import EngineCore
import Foundation
import MacDriver
@testable import MacSession
import Synchronization
import Testing

/// Issue #42 on the real Mac. BRAUS_MAC_LIVE_TESTS=1 and BRAUS_MAC_NOTES_TESTS=1, the desktop free:
/// Notes is opened on the MacDriver, "Nuova nota" is pressed (it creates a note) and text is inserted.
/// The front app is sampled every 30 ms throughout, so the run shows which step brings Notes in front,
/// whether the person's app comes back, and what the session does next. Labels of an Italian Mac.
@MainActor
@Suite("Mac front apps, live", .serialized)
struct MacFrontLiveTests {

    @Test("Notes: the step that brings it in front, the person's app brought back, and the handoff after",
          .enabled(if: ProcessInfo.processInfo.environment["BRAUS_MAC_LIVE_TESTS"] == "1"
                   && ProcessInfo.processInfo.environment["BRAUS_MAC_NOTES_TESTS"] == "1"))
    func notes() async throws {
        let front = NSWorkspace.shared.frontmostApplication
        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("mac-front-\(UUID().uuidString)")
        let session = MacAutomationSession(knowledgeDirectory: knowledge)
        let clock = ContinuousClock()
        let started = clock.now
        let samples = Mutex<[(at: Duration, app: String)]>([])
        let sampler = Task.detached {
            var last = ""
            while !Task.isCancelled {
                // Off the main actor, which a long accessibility press blocks.
                let app = Self.frontName()
                if app != last {
                    last = app
                    samples.withLock { $0.append((clock.now - started, app)) }
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        func mark(_ step: String) { print("[\(clock.now - started)] \(step)") }

        mark("front before: \(front?.localizedName ?? "none")")
        do {
            _ = try await session.open(application: "Notes", window: nil)
            mark("open_session: on the MacDriver")
        } catch let handoff as MacHandoff {
            mark("open_session: handoff, \(handoff.reason)")
        }
        if session.id != nil {
            let act = try await session.act(target: "Nuova nota", verb: .click, section: nil, desiredState: nil)
            mark("act 'Nuova nota': \(act.kind.rawValue): \(act.message)")
            do {
                let typed = try await session.deliver(.insertText("Braus focus test"), section: nil)
                mark("insert_text: \(typed.kind.rawValue): \(typed.message)")
            } catch let handoff as MacHandoff {
                mark("insert_text: handoff \(handoff), \(handoff.reason)")
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
        sampler.cancel()
        await session.close()
        for sample in samples.withLock({ $0 }) { print("front at \(sample.at): \(sample.app)") }
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front?.processIdentifier,
                "the person's app is in front at the end")
    }

    /// The front app's name from Launch Services, without the main run loop.
    nonisolated static func frontName() -> String {
        func run(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let asn = run(["front"])
        return run(["info", "-only", "name", asn])
    }
}
