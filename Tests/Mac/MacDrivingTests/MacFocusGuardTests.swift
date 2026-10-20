import Foundation
import MacDriver
import Synchronization
import Testing

/// A workspace whose activation takes effect `lag` after the call, as the window server's does.
final class LaggingWorkspace: MacWorkspace {
    let lag: Duration
    let front: Mutex<MacRunningApp?>
    init(front: MacRunningApp, lag: Duration) { self.front = Mutex(front); self.lag = lag }

    func installedApplications() -> [MacApp] { [] }
    func application(bundleID: String) -> MacApp? { nil }
    func application(at url: URL) -> MacApp? { nil }
    func running(bundleID: String) -> MacRunningApp? { nil }
    func frontmost() async -> MacRunningApp? { front.withLock { $0 } }
    func launch(_ app: MacApp) async throws -> MacRunningApp { MacRunningApp(processID: 500, bundleID: app.bundleID) }
    func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp { try await launch(app) }
    func openLink(_ link: URL) async throws {}
    func defaultApplication(for item: URL) -> MacApp? { nil }
    func activate(_ processID: pid_t) async {
        let lag = lag
        Task.detached { [self] in
            try? await Task.sleep(for: lag)
            self.front.withLock { $0 = MacRunningApp(processID: processID) }
        }
    }
    func secondsSincePersonInput() -> TimeInterval { 600 }
}

@Suite("MacDriver focus guard")
struct MacFocusGuardTests {

    static let person = MacRunningApp(processID: 42, bundleID: "com.anthropic.claudefordesktop")
    static let app = MacRunningApp(processID: 500, bundleID: "ai.storyteller.gridcraft")

    @Test("an activation that lands a moment after the call still counts as restored")
    func lateActivationRestores() async {
        let workspace = LaggingWorkspace(front: Self.person, lag: .milliseconds(150))
        let focusGuard = await MacFocusGuard.begin(workspace)
        workspace.front.withLock { $0 = Self.app }
        let outcome = await focusGuard.settle(after: Self.app.processID)
        #expect(outcome.selfActivated && outcome.focusRestored && !outcome.leftInFront)
    }

    @Test("an activation that never lands is not restored, after the wait")
    func neverRestored() async {
        let workspace = LaggingWorkspace(front: Self.person, lag: .seconds(5))
        let focusGuard = await MacFocusGuard.begin(workspace)
        workspace.front.withLock { $0 = Self.app }
        let outcome = await focusGuard.settle(after: Self.app.processID)
        #expect(outcome.selfActivated && !outcome.focusRestored && outcome.leftInFront)
    }
}
