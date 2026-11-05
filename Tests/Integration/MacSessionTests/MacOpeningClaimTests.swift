import AutomationRuntime
import Foundation
import MacDriver
import MacDriving
import MacSession
import Synchronization
import Testing

@MainActor
struct MacOpeningClaimTests {
    @Test(arguments: [false, true])
    func failedOrCancelledPreparationKeepsAAndReleasesOnlyB(_ cancelled: Bool) async throws {
        let other = MacApp(bundleID: "com.example.other", url: URL(fileURLWithPath: "/Applications/Other.app"), names: ["Other"])
        let workspace = SuspendedWorkspace(WorkspaceStub(apps: [MacSessionTests.notes, other], processIDs: [other.bundleID: 501]), fail: !cancelled)
        let reader = TreeStub(MacSessionTests.rich)
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
            notifications: QuietNotifications(), controls: NoControls(),
            serverWindows: { _ in [(number: 7, frame: MacSessionTests.frame)] },
            identity: { _ in (MacSessionTests.notes.bundleID, "Notes") })
        let claims = AppClaims()
        let session = MacAutomationSession(knowledgeDirectory: .temporaryDirectory.appending(path: "mac-claim-\(UUID())"),
            roles: roles, workspace: workspace, leases: claims)
        _ = try await session.open(application: "Notes", window: nil)
        let original = try #require(session.id)
        let replacing = Task { try await session.open(application: "Other", window: nil) }
        for _ in 0..<200 where !workspace.isWaiting { try await Task.sleep(for: .milliseconds(1)) }
        guard workspace.isWaiting else {
            _ = try await replacing.value
            Issue.record("The replacement never reached its launch barrier")
            await session.close()
            return
        }
        for bundle in [MacSessionTests.notes.bundleID, other.bundleID] {
            if case .success = claims.acquire(bundle, owner: UUID()) { Issue.record("Claim released during preparation") }
        }
        if cancelled { replacing.cancel() }
        workspace.resume()
        do {
            _ = try await replacing.value
            Issue.record("The replacement must fail")
        } catch { #expect((error is CancellationError) == cancelled) }
        #expect(session.id == original && session.memoryApplication == MacSessionTests.notes.bundleID)
        #expect(workspace.base.running(bundleID: other.bundleID) != nil, "A failed acquisition does not undo a launch")
        _ = try await session.observe()
        if case .success = claims.acquire(MacSessionTests.notes.bundleID, owner: UUID()) {
            Issue.record("A lost its claim after B failed")
        }
        if case .failure = claims.acquire(other.bundleID, owner: UUID()) { Issue.record("B's temporary claim leaked") }
        await session.close()
        if case .failure = claims.acquire(MacSessionTests.notes.bundleID, owner: UUID()) { Issue.record("A's claim leaked") }
    }
    @Test func sceneFailureAfterLaunchRetainsThePriorRuntimeAndClaim() async throws {
        let other = MacApp(bundleID: "com.example.other", url: URL(fileURLWithPath: "/Applications/Other.app"), names: ["Other"])
        let workspace = WorkspaceStub(apps: [MacSessionTests.notes, other], processIDs: [other.bundleID: 501])
        let reader = TreeStub(MacSessionTests.rich)
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
            notifications: QuietNotifications(), controls: NoControls(),
            serverWindows: { _ in [(number: 7, frame: MacSessionTests.frame)] },
            identity: { pid in pid == 501 ? ("com.example.other", "Other") : (MacSessionTests.notes.bundleID, "Notes") })
        let claims = AppClaims()
        let session = MacAutomationSession(knowledgeDirectory: .temporaryDirectory.appending(path: "mac-scene-fail-\(UUID())"),
            roles: roles, workspace: workspace, leases: claims)
        _ = try await session.open(application: "Notes", window: nil)
        let original = session.id
        reader.failedReadPIDs.withLock { $0.insert(501) }
        do {
            _ = try await session.open(application: "Other", window: nil)
            Issue.record("B's scene must fail")
        } catch {}
        #expect(workspace.running(bundleID: other.bundleID) != nil)
        #expect(session.id == original && session.memoryApplication == MacSessionTests.notes.bundleID)
        _ = try await session.observe()
        if case .failure = claims.acquire(other.bundleID, owner: UUID()) { Issue.record("B's claim leaked") }
        if case .success = claims.acquire(MacSessionTests.notes.bundleID, owner: UUID()) { Issue.record("A's claim was lost") }
        await session.close()
    }

}

/// SuspendedWorkspace launches a simulated B, then ignores cancellation until the test resumes it.
private final class SuspendedWorkspace: MacWorkspace {
    let base: WorkspaceStub
    let fail: Bool
    private let pending = Mutex<CheckedContinuation<Void, Never>?>(nil)
    var isWaiting: Bool { pending.withLock { $0 != nil } }
    init(_ base: WorkspaceStub, fail: Bool) { self.base = base; self.fail = fail }
    func resume() {
        let continuation = pending.withLock { value in let saved = value; value = nil; return saved }
        continuation?.resume()
    }
    func installedApplications() -> [MacApp] { base.installedApplications() }
    func application(bundleID: String) -> MacApp? { base.application(bundleID: bundleID) }
    func application(at url: URL) -> MacApp? { nil }
    func running(bundleID: String) -> MacRunningApp? { base.running(bundleID: bundleID) }
    func frontmost() async -> MacRunningApp? { await base.frontmost() }
    func launch(_ app: MacApp) async throws -> MacRunningApp {
        let process = try await base.launch(app)
        if app.bundleID == "com.example.other" {
            await withCheckedContinuation { continuation in pending.withLock { $0 = continuation } }
            if fail { throw AutomationFailure("Synthetic launch failure after preparation") }
        }
        return process
    }
    func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp { try await launch(app) }
    func openLink(_ link: URL) async throws {}
    func defaultApplication(for item: URL) -> MacApp? { nil }
    func activate(_ processID: pid_t) async { await base.activate(processID) }
    func secondsSincePersonInput() -> TimeInterval { 600 }
}
