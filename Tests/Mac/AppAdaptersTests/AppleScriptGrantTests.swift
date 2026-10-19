import Carbon
import Foundation
import Synchronization
import Testing
@testable import AppAdapters

/// A01: what the Mac's answer to "may Braus send this app events", asked without prompting, states. Only `noErr` is a
/// grant; consent needed or refused is refused; an app not running, or any other answer, is not known.
@Suite("AppleScript grant")
struct AppleScriptGrantTests {

    @Test("only noErr is allowed; consent needed or refused is refused; an app not running or another answer is not known")
    func grants() {
        #expect(AppleScriptRunner.grant(status: OSStatus(noErr)) == .allowed)
        #expect(AppleScriptRunner.grant(status: OSStatus(errAEEventWouldRequireUserConsent)) == .refused)
        #expect(AppleScriptRunner.grant(status: OSStatus(errAEEventNotPermitted)) == .refused)
        #expect(AppleScriptRunner.grant(status: OSStatus(procNotFound)) == .notAnswerable)
        #expect(AppleScriptRunner.grant(status: -1) == .notAnswerable)
    }

    @Test("a script goes only on an allowed grant; a refused one and an unanswered one stop it before any event, each saying which")
    func dispatch() throws {
        #expect((try? AppleScriptRunner.dispatch(for: .allowed, app: "Mail").get()) != nil)
        for grant in [AppleScriptRunner.Grant.refused, .notAnswerable] {
            guard case .failure(let stopped) = AppleScriptRunner.dispatch(for: grant, app: "Mail") else {
                Issue.record("\(grant) let the script go")
                continue
            }
            #expect(stopped.beforeAnyEvent, "\(grant): stopped before any event")
            #expect(stopped.isGrantUnknown == (grant == .notAnswerable), "\(grant): unknown is told apart from refused")
        }
    }

    /// Gauge counts the scripts running at once, the most ever seen, and those run on the main thread.
    private final class Gauge: Sendable {
        let counts = Mutex((running: 0, peak: 0, onMain: 0, runs: 0))
    }

    @Test("scripts on the queue run one at a time, and never on the main thread")
    func scriptsRunOneAtATime() async throws {
        let gauge = Gauge()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await ScriptQueue.shared.run {
                        gauge.counts.withLock { counts in
                            counts.running += 1
                            counts.runs    += 1
                            counts.peak     = max(counts.peak, counts.running)
                            if Thread.isMainThread { counts.onMain += 1 }
                        }
                        // Long enough for another task to start a script, were the queue not serial.
                        usleep(5_000)
                        gauge.counts.withLock { $0.running -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        let counts = gauge.counts.withLock { $0 }
        #expect(counts.runs == 8)
        #expect(counts.peak == 1, "two scripts ran at once")
        #expect(counts.onMain == 0)
    }
}
