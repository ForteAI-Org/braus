import AppKit
import AutomationRuntime
import AutomationMCP
import LocalMCP
import EngineCore
import Foundation
import PerceptionCore
import SeatDriving
import SeatSession
@testable import SeatBroker
import Testing

@MainActor
struct BrokeredOpeningContractTests {
    private final class Running: NSRunningApplication {
        let bundle: String
        init(_ bundle: String) { self.bundle = bundle; super.init() }
        override var isTerminated: Bool { false }
        override var bundleIdentifier: String? { bundle }
        override var localizedName: String? { bundle == "test.a" ? "App A" : "App B" }
        override var processIdentifier: pid_t { bundle == "test.a" ? 601 : 602 }
    }

    @MainActor
    private final class Fixture {
        let broker = SeatBroker()
        let claims = AppClaims()
        let owner = UUID()
        var app = "test.a"
        var openings: [String] = []
        var reads = 0
        var onRead: (() throws -> Void)?
        var unresolved: String?
        var preparation: ((String) async throws -> Void)?
        lazy var session = BrokeredAutomationSession(
            broker: broker, workerID: owner,
            knowledgeDirectory: .temporaryDirectory.appending(path: "broker-switch-\(UUID())"),
            allowsDestructive: false, claims: claims, resolving: { [weak self] word in
                guard let self else { throw CancellationError() }
                if unresolved == word { throw AutomationFailure("Synthetic unresolved app") }
                return word == "App A" || word == "Alias A" ? "test.a" : word == "App B" ? "test.b" : word
            }, missingGrant: { nil }, requestGrants: {}, seating: { [weak self] _, bundle, _ in
                guard let self else { throw CancellationError() }
                openings.append(bundle)
                try await preparation?(bundle)
                app = bundle
                return (TargetApp(pid: bundle == "test.a" ? 601 : 602, bundleID: bundle,
                    name: bundle == "test.a" ? "App A" : "App B", bundleURL: nil, windows: []), SeatTarget())
            }, perceiving: { [weak self] _, _ in
                guard let self else { throw CancellationError() }
                reads += 1
                try onRead?()
                return SceneSnapshot(bundleID: app, appName: app, windowTitle: app,
                    viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
            }, runningApplication: { Running($0 == 601 ? "test.a" : "test.b") }, stoppedForGood: { _ in false })
    }

    @Test func sameAppResumesWithoutAnotherSeating() async throws {
        let fixture = Fixture(), desktop = fixture.session
        _ = try await desktop.open(application: "App A", window: nil)
        let original = desktop.id
        _ = try await desktop.open(application: "Alias A", window: nil)
        #expect(desktop.id == original && fixture.openings == ["test.a"] && fixture.reads == 2)
        await desktop.close()
        #expect(fixture.broker.queue.entries.isEmpty)
    }

    @Test func changesAppsOnTheSameLeaseAndCanReturn() async throws {
        let fixture = Fixture(), desktop = fixture.session
        _ = try await desktop.open(application: "App A", window: nil)
        let entries = fixture.broker.queue.entries
        _ = try await desktop.open(application: "App B", window: nil)
        #expect(desktop.memoryApplication == "test.b" && fixture.broker.queue.entries == entries)
        _ = try await desktop.open(application: "App A", window: nil)
        #expect(desktop.memoryApplication == "test.a")
        #expect(fixture.openings == ["test.a", "test.b", "test.a"])
        await desktop.close()
        #expect(fixture.broker.queue.entries.isEmpty)
    }

    @Test func unresolvedReplacementKeepsPreviousIdentityAndClaim() async throws {
        let fixture = Fixture(), desktop = fixture.session
        _ = try await desktop.open(application: "App A", window: nil)
        let original = desktop.id
        fixture.unresolved = "App B"
        await #expect(throws: AutomationFailure.self) { try await desktop.open(application: "App B", window: nil) }
        #expect(desktop.id == original && desktop.memoryApplication == "test.a")
        switch fixture.claims.acquire("test.a", owner: UUID()) {
        case .success: Issue.record("A's claim must remain owned")
        case .failure: break
        }
        _ = try await desktop.observe()
        await desktop.close()
    }

    @Test(arguments: [false, true])
    func retainedNoWindowRefusalReportsActualLaunchFacts(_ wasLaunched: Bool) async throws {
        let fixture = Fixture(), desktop = fixture.session
        _ = try await desktop.open(application: "App A", window: nil)
        let original = desktop.id, entries = fixture.broker.queue.entries
        fixture.preparation = { bundle in
            if bundle == "test.b" {
                throw AgentSession.ReplacementFailure(underlying: SeatBrokerError.noWindowShown(
                    application: "App B", seconds: 1, wasLaunched: wasLaunched, wasQuit: wasLaunched),
                    previousRetained: true)
            }
        }
        do {
            _ = try await desktop.open(application: "App B", window: nil)
            Issue.record("Expected a refused replacement")
        } catch let failure as ApplicationOpeningFailure {
            #expect(failure.state == .previousRetained)
            let description = ModelText.openingFailure(failure)
            #expect(description.contains("was launched in the background") == wasLaunched)
            #expect(description.contains("App B is running") == !wasLaunched)
            #expect(description.contains("previous application session is still active"))
            #expect(!description.contains("computer was given back"))
        }
        #expect(desktop.id == original && desktop.memoryApplication == "test.a")
        #expect(fixture.broker.queue.entries == entries)
        _ = try await desktop.observe()
        await desktop.close()
        #expect(fixture.broker.queue.entries.isEmpty)
    }

    @Test func humanInterruptionAfterReplacementKeepsTheAdoptedB() async throws {
        let fixture = Fixture(), desktop = fixture.session
        let tools = AutomationTools(session: desktop)
        _ = try await tools.call("open_session", .object(["app": .string("App A")]))
        let original = desktop.id
        let interruption = AutomationCallInterruption()
        fixture.onRead = { [weak fixture] in
            if fixture?.app == "test.b" {
                interruption.interruptForHumanControl()
                throw CancellationError()
            }
        }
        let answer = try await AutomationCallInterruption.$current.withValue(interruption) {
            try await tools.call("open_session", .object(["app": .string("App B")]))
        }
        let text = try #require(answer["content"].array?.first?["text"].string)
        #expect(text.contains("\"opened\":true") && !text.contains("\"scene\":"))
        #expect(desktop.id != nil && desktop.id != original && desktop.memoryApplication == "test.b")
        #expect(fixture.broker.queue.entries.count == 1)
        fixture.onRead = nil
        _ = try await desktop.observe()
        await desktop.close()
        #expect(fixture.broker.queue.entries.isEmpty)
    }

    @Test func cancellationAfterPreparationCannotPublishANewSession() async throws {
        let fixture = Fixture(), desktop = fixture.session
        _ = try await desktop.open(application: "App A", window: nil)
        var continuation: CheckedContinuation<Void, Never>?
        fixture.preparation = { bundle in
            if bundle == "test.b" { await withCheckedContinuation { continuation = $0 } }
        }
        let replacing = Task { try await desktop.open(application: "App B", window: nil) }
        for _ in 0..<200 where continuation == nil && !replacing.isCancelled {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let resume = continuation else {
            await desktop.close()
            _ = try await replacing.value
            Issue.record("The replacement never reached preparation")
            return
        }
        for bundle in ["test.a", "test.b"] {
            switch fixture.claims.acquire(bundle, owner: UUID()) {
            case .success: Issue.record("The in-flight claim for \(bundle) was released early")
            case .failure: break
            }
        }
        replacing.cancel()
        resume.resume()
        await #expect(throws: CancellationError.self) { try await replacing.value }
        #expect(desktop.id == nil && desktop.memoryApplication == nil)
        #expect(fixture.broker.queue.entries.isEmpty)
        await desktop.close()
        for bundle in ["test.a", "test.b"] {
            if case .failure = fixture.claims.acquire(bundle, owner: UUID()) {
                Issue.record("The drained replacement leaked \(bundle)")
            }
        }
    }
}
