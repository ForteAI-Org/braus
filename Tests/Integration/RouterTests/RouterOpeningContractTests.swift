import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore
import Router
import Testing

@MainActor
struct RouterOpeningContractTests {
    @Test(arguments: [false, true])
    func failedReplacementPreservesPreviousRoute(_ cancelled: Bool) async throws {
        let native = OpeningSession(), web = OpeningSession()
        let router = RoutingAutomationSession(native: native, desktop: OpeningSession(), web: web)
        _ = try await router.open(application: "App A", window: "A window")
        let original = try #require(router.id)
        web.failure = cancelled ? CancellationError() : AutomationFailure("Synthetic B failure")
        do {
            _ = try await router.open(application: "web:example.test", window: "B window")
            Issue.record("B must fail")
        } catch {
            #expect((error is CancellationError) == cancelled)
        }
        #expect(router.id == original)
        #expect(native.closeCount == 0)
        #expect(web.closeCount == 1 && !web.hasResource)
        _ = try await router.observe()
        #expect(native.observed == 1 && web.observed == 0)
        await router.close()
        #expect(native.closeCount == 1 && web.closeCount == 1)
    }

    @Test func replacementAcquiresBeforeReleasingPreviousControl() async throws {
        let native = OpeningSession(), web = OpeningSession()
        let router = RoutingAutomationSession(native: native, desktop: OpeningSession(), web: web)
        _ = try await router.open(application: "App A", window: nil)
        let original = try #require(router.id)
        web.onPrepare = {
            #expect(native.id == original && native.resourceReleases == 0)
        }
        _ = try await router.open(application: "web:example.test", window: nil)
        #expect(router.id == web.id && native.id == nil)
        #expect(native.resourceReleases == 1 && web.resourceReleases == 0)
        await router.close()
        await router.close()
        #expect(native.resourceReleases == 1 && web.resourceReleases == 1)
    }

    @Test func resumingTheHeldDesktopAppDoesNotReacquireItThroughNative() async throws {
        let native = OpeningSession(), desktop = OpeningSession()
        native.openingHandoff = HandoffStub(bundleID: "com.example.a")
        let router = RoutingAutomationSession(native: native, desktop: desktop)
        _ = try await router.open(application: "App A", window: "A window")
        let original = try #require(router.id)
        native.openingHandoff = nil
        _ = try await router.open(application: "App A", window: nil)
        #expect(router.id == original && router.memoryApplication == "com.example.a")
        #expect(native.launches == 0 && desktop.launches == 1)
        #expect(desktop.resourceReleases == 0)
        await router.close()
        #expect(desktop.resourceReleases == 1)
    }

    @Test func aNilWindowResumeKeepsTheObservedWindowForALaterHandoff() async throws {
        let native = OpeningSession(), desktop = OpeningSession()
        let router = RoutingAutomationSession(native: native, desktop: desktop)
        _ = try await router.open(application: "App A", window: "A window")
        native.scene.windowTitle = "A freshly observed window"
        _ = try await router.open(application: "App A", window: nil)
        native.laterHandoff = HandoffStub(bundleID: "com.example.a")
        _ = try await router.observe()
        #expect(desktop.lastWindow == "A freshly observed window")
        await router.close()
    }

    @Test func failedSameRouteSwitchKeepsIdentityAndCanReturnToPreviousApp() async throws {
        let native = OpeningSession()
        let router = RoutingAutomationSession(native: native, desktop: OpeningSession())
        _ = try await router.open(application: "App A", window: nil)
        let original = router.id
        native.failure = AutomationFailure("B unavailable")
        await #expect(throws: AutomationFailure.self) {
            try await router.open(application: "App B", window: nil)
        }
        #expect(router.id == original && native.closeCount == 0)
        native.failure = nil
        _ = try await router.open(application: "App A", window: nil)
        #expect(router.id == original && native.launches == 1)
        await router.close()
        #expect(native.closeCount == 1)
    }
}

/// Preparation may acquire a resource before failing; replacement commits only on success.
@MainActor
private final class OpeningSession: AutomationSessionOperating {
    var id: UUID?
    var application: String?
    var failure: (any Error)?
    var onPrepare: (() -> Void)?
    var resourceReleases = 0
    var openingHandoff: HandoffStub?
    var laterHandoff: HandoffStub?
    var lastWindow: String?
    var hasResource = false
    var closeCount = 0
    var observed = 0
    var launches = 0
    var memoryApplication: String? { application }
    var scene = SceneSnapshot(bundleID: "test.app", appName: "App", windowTitle: "Window",
        viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])

    func resolvedBundleID(of application: String) async -> String? {
        ["App A": "com.example.a", "com.example.a": "com.example.a"][application]
    }
    func open(application: String, window: String?) async throws -> SceneSnapshot {
        let application = await resolvedBundleID(of: application) ?? application
        if application == self.application && window == nil { return try await observe() }
        onPrepare?()
        hasResource = true
        if let openingHandoff { throw openingHandoff }
        if let failure { throw failure }
        self.application = application
        lastWindow = window
        if let window { scene.windowTitle = window }
        launches += 1
        id = UUID()
        return scene
    }
    func observe() async throws -> SceneSnapshot {
        if let laterHandoff { id = nil; throw laterHandoff }
        observed += 1
        return scene
    }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        ActOutcome(.refused, "Synthetic session")
    }
    func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.refused, "Synthetic session") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        ActOutcome(.refused, "Synthetic session")
    }
    func close() async {
        closeCount += 1
        if hasResource { resourceReleases += 1 }
        id = nil
        hasResource = false
        application = nil
    }
}
