import AutomationRuntime
import CoreGraphics
import Foundation
import EngineCore
import PerceptionCore
import Synchronization
import MacDriver
import MacDriving
import MacSession
import Testing

@MainActor
struct MacOpeningResumeTests {
    private func session() -> (MacAutomationSession, WorkspaceStub, TreeStub) {
        let other = MacApp(bundleID: "com.example.other", url: URL(fileURLWithPath: "/Applications/Other.app"), names: ["Other"])
        let workspace = WorkspaceStub(apps: [MacSessionTests.notes, other], processIDs: [other.bundleID: 501])
        var otherTree = MacSessionTests.rich
        otherTree.title = "Other"
        let reader = TreeStub(MacSessionTests.rich, trees: [501: otherTree])
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
            notifications: QuietNotifications(), controls: NoControls(),
            serverWindows: { pid in [(number: Int(pid) + 700, frame: MacSessionTests.frame)] },
            identity: { pid in pid == 501 ? ("com.example.other", "Other") : (MacSessionTests.notes.bundleID, "Notes") })
        return (MacAutomationSession(knowledgeDirectory: .temporaryDirectory.appending(path: "mac-resume-\(UUID())"),
            roles: roles, workspace: workspace, leases: MacAppLeases()), workspace, reader)
    }

    @Test func sameAppWithoutWindowResumesExistingSession() async throws {
        let (session, _, _) = session()
        _ = try await session.open(application: "Notes", window: nil)
        let original = try #require(session.id)
        _ = try await session.open(application: MacSessionTests.notes.bundleID, window: nil)
        #expect(session.id == original && session.memoryApplication == MacSessionTests.notes.bundleID)
        await session.close()
    }

    @Test func differentAppReplacesRuntimeAndOldAppRemainsRunning() async throws {
        let (session, workspace, reader) = session()
        _ = try await session.open(application: "Notes", window: nil)
        let original = try #require(session.id)
        let other = try await session.open(application: "Other", window: nil)
        #expect(other.bundleID == "com.example.other" && other.windowTitle == "Other")
        _ = try await session.act(target: "B3", verb: .click, section: nil, desiredState: nil)
        #expect(reader.performedProcessIDs.withLock { $0.last } == 501)
        #expect(session.id != nil && session.id != original)
        #expect(session.memoryApplication == "com.example.other")
        #expect(workspace.running(bundleID: MacSessionTests.notes.bundleID) != nil)
        let resumed = try await session.open(application: "Notes", window: nil)
        #expect(resumed.bundleID == MacSessionTests.notes.bundleID && resumed.windowTitle == "Notes")
        #expect(session.memoryApplication == MacSessionTests.notes.bundleID)
        await session.close()
    }

    @Test func cancelledReplacementPreservesPriorIdentity() async throws {
        let (session, _, _) = session()
        _ = try await session.open(application: "Notes", window: nil)
        let original = session.id
        let replacement = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.open(application: "Other", window: nil)
        }
        await #expect(throws: CancellationError.self) { try await replacement.value }
        #expect(session.id == original && session.memoryApplication == MacSessionTests.notes.bundleID)
        _ = try await session.observe()
        await session.close()
    }
}
