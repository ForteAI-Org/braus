import CoreGraphics
import Foundation
@testable import SeatBroker
import Testing

/// Exercises AgentSession's own state and cleanup, substituting only platform operations.
@MainActor
@Suite(.serialized)
struct AgentSessionReplacingBoundaryTests {
    @MainActor
    private final class Trace {
        var events: [String] = []
        var adopted: pid_t?
        var released: pid_t?
        var terminated: Set<pid_t> = []
        var failAdoption = false
        var suspendAdoption = false
        var warnOnBHandback = false
        var pending: CheckedContinuation<Void, Never>?
    }

    @MainActor
    private final class Fixture {
        let trace: Trace
        let session: AgentSession
        let root: URL

        init(launchFailure: (wasLaunched: Bool, wasQuit: Bool)? = nil) {
            let trace = Trace()
            self.trace = trace
            let root = FileManager.default.temporaryDirectory.appending(path: "agent-replacement-\(UUID())")
            self.root = root
            let ledger = LaunchLedger(
                terminate: { pid in
                    trace.events.append("quit:\(pid)")
                    trace.terminated.insert(pid)
                },
                isTerminated: { trace.terminated.contains($0) }
            )
            // A was launched by this owner before the replacement under test.
            ledger.record(.openedByAgent, for: 601)
            let broker = SeatBroker(configuration: .init(
                perceptionStoreDirectory: root.appending(path: "Perception"),
                recordingDirectory: root.appending(path: "Runs")
            ), ledger: ledger)
            let session = broker.openSession()
            self.session = session
            let aWindow = TargetWindow(pid: 601, windowNumber: 701, title: "A window",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            let bWindow = TargetWindow(pid: 602, windowNumber: 702, title: "B window",
                frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            let a = TargetApp(pid: 601, bundleID: "test.a", name: "A", bundleURL: nil, windows: [aWindow])
            let b = TargetApp(pid: 602, bundleID: "test.b", name: "B", bundleURL: nil, windows: [bWindow])
            session.openingPlatform = AgentSession.OpeningPlatform(
                resolve: { name in
                    trace.events.append("resolve:\(name)")
                    guard name == "A" || name == "B" else {
                        throw SeatBrokerError.applicationNotResolved("Unknown synthetic application")
                    }
                    if name == "A" { return a }
                    return TargetApp(pid: launchFailure?.wasLaunched == false ? 602 : nil,
                        bundleID: "test.b", name: "B", bundleURL: nil, windows: [])
                },
                launch: { app in
                    trace.events.append("launch:\(app.name)")
                    if app.bundleID == "test.b", let launchFailure {
                        throw SeatBrokerError.noWindowShown(application: "B", seconds: 0,
                            wasLaunched: launchFailure.wasLaunched, wasQuit: launchFailure.wasQuit)
                    }
                    if app.bundleID == "test.b" { ledger.record(.openedByAgent, for: 602) }
                    return app.bundleID == "test.a" ? a : b
                },
                adopt: { window in
                    trace.events.append("adopt:\(window.pid)")
                    trace.adopted = window.pid
                    if window.pid == 602, trace.failAdoption {
                        throw SeatBrokerError.driver("Synthetic B adoption failed after acquisition")
                    }
                    if window.pid == 602, trace.suspendAdoption {
                        try Task.checkCancellation()
                        await withCheckedContinuation { trace.pending = $0 }
                        try Task.checkCancellation()
                    }
                },
                release: {
                    trace.events.append("release:\(trace.adopted ?? 0)")
                    trace.released = trace.adopted
                    trace.adopted = nil
                },
                handback: {
                    trace.events.append("handback:\(trace.released ?? 0)")
                    return trace.warnOnBHandback && trace.released == 602 ? "B handback was not confirmed" : nil
                },
                hasUnrestoredWindow: { false }
            )
            session.stopHost = { trace.events.append("stop"); return nil }
        }

        func openA() async throws {
            _ = try await session.open(applicationNamed: "A", windowTitled: "A window")
            #expect(session.isUsingApp && session.app?.bundleID == "test.a" && session.target?.pid == 601)
        }

        func close() async throws {
            let warning = await session.close()
            #expect(warning == nil)
            try FileManager.default.removeItem(at: root)
        }
    }

    @Test(arguments: [(false, false), (true, false), (true, true)])
    func failureBeforeTransferKeepsAAndTypedCause(wasLaunched: Bool, wasQuit: Bool) async throws {
        let fixture = Fixture(launchFailure: (wasLaunched, wasQuit))
        try await fixture.openA()
        let boundary = fixture.trace.events.count
        do {
            _ = try await fixture.session.openReplacingApplication("B", window: "B window")
            Issue.record("The synthetic launch must fail")
        } catch let failure as AgentSession.ReplacementFailure {
            #expect(failure.previousRetained)
            guard case .noWindowShown(let name, let seconds, let launched, let quit)? = failure.underlying as? SeatBrokerError else {
                Issue.record("The typed launch facts were lost")
                try await fixture.close()
                return
            }
            #expect(name == "B" && seconds == 0 && launched == wasLaunched && quit == wasQuit)
        }
        #expect(fixture.session.isUsingApp && fixture.session.app?.bundleID == "test.a")
        #expect(fixture.session.target?.pid == 601 && fixture.trace.adopted == 601)
        #expect(Array(fixture.trace.events.dropFirst(boundary)) == ["resolve:B", "launch:B"])
        try await fixture.close()
        #expect(fixture.trace.events.filter { $0 == "release:601" }.count == 1)
        #expect(fixture.trace.events.filter { $0 == "quit:601" }.count == 1)
    }

    @Test
    func failureAfterTransferLeavesEmptyAndCleansBWithoutReplay() async throws {
        let fixture = Fixture()
        try await fixture.openA()
        fixture.trace.failAdoption = true
        let boundary = fixture.trace.events.count
        do {
            _ = try await fixture.session.openReplacingApplication("B", window: "B window")
            Issue.record("The synthetic adoption must fail")
        } catch let failure as AgentSession.ReplacementFailure {
            #expect(!failure.previousRetained)
            #expect(failure.underlying.localizedDescription.contains("Synthetic B adoption failed"))
        }
        #expect(!fixture.session.isUsingApp && fixture.trace.adopted == nil)
        // AgentSession keeps the last requested app/target, not a claim that it is still adopted.
        #expect(fixture.session.app?.bundleID == "test.b" && fixture.session.target?.pid == 602)
        #expect(Array(fixture.trace.events.dropFirst(boundary)) == [
            "resolve:B", "launch:B", "release:601", "handback:601", "quit:601",
            "adopt:602", "release:602", "handback:602", "quit:602"
        ])
        try await fixture.close()
        #expect(fixture.trace.events.filter { $0 == "release:602" }.count == 1)
        #expect(fixture.trace.events.filter { $0 == "quit:602" }.count == 1)
        #expect(fixture.trace.events.filter { $0 == "launch:A" }.count == 1)
    }

    @Test
    func cancellationDuringAdoptionPreservesCancellationAndCleansB() async throws {
        let fixture = Fixture()
        try await fixture.openA()
        fixture.trace.suspendAdoption = true
        let replacing = Task { try await fixture.session.openReplacingApplication("B", window: "B window") }
        for _ in 0..<200 where fixture.trace.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        guard let pending = fixture.trace.pending else {
            replacing.cancel()
            fixture.trace.pending?.resume()
            _ = await replacing.result
            try await fixture.close()
            Issue.record("The replacement never reached the adoption barrier")
            return
        }
        #expect(fixture.session.isUsingApp && fixture.session.app?.bundleID == "test.b")
        #expect(fixture.trace.adopted == 602 && fixture.trace.terminated.contains(601))
        replacing.cancel()
        pending.resume()
        fixture.trace.pending = nil
        do {
            _ = try await replacing.value
            Issue.record("Cancellation must be preserved")
        } catch let failure as AgentSession.ReplacementFailure {
            #expect(!failure.previousRetained && failure.underlying is CancellationError)
        }
        #expect(!fixture.session.isUsingApp && fixture.trace.adopted == nil)
        #expect(fixture.trace.events.filter { $0 == "release:602" }.count == 1)
        #expect(fixture.trace.events.filter { $0 == "quit:602" }.count == 1)
        #expect(fixture.trace.events.filter { $0 == "launch:A" }.count == 1)
        try await fixture.close()
        #expect(fixture.trace.events.filter { $0 == "release:602" }.count == 1)
    }
    @Test func cancelledAdoptionKeepsCleanupWarningSeparateFromCancellation() async throws {
        let fixture = Fixture()
        try await fixture.openA()
        fixture.trace.suspendAdoption = true
        fixture.trace.warnOnBHandback = true
        let replacing = Task { try await fixture.session.openReplacingApplication("B", window: "B window") }
        for _ in 0..<200 where fixture.trace.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        guard let pending = fixture.trace.pending else {
            replacing.cancel()
            _ = await replacing.result
            try await fixture.close()
            Issue.record("The replacement never reached adoption")
            return
        }
        replacing.cancel()
        pending.resume()
        fixture.trace.pending = nil
        do {
            _ = try await replacing.value
            Issue.record("Cancellation must be preserved")
        } catch let failure as AgentSession.ReplacementFailure {
            #expect(!failure.previousRetained && failure.underlying is CancellationError)
            #expect(failure.cleanupWarning?.contains("B handback was not confirmed") == true)
        }
        #expect(!fixture.session.isUsingApp)
        #expect(fixture.trace.events.filter { $0 == "release:602" }.count == 1)
        #expect(!fixture.trace.terminated.contains(602), "A failed handback must not terminate B")
        let warning = await fixture.session.close()
        #expect(warning?.contains("B handback was not confirmed") == true)
        #expect(await fixture.session.close() == nil)
        #expect(fixture.trace.events.filter { $0 == "release:602" }.count == 1)
        try FileManager.default.removeItem(at: fixture.root)
    }

}
