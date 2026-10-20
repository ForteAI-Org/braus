import AppKit
import AutomationRuntime
import Foundation
import PerceptionCore
import SeatBroker
import Testing
import WindowServerListing

/// Measures, on the real Mac, whether an app adopted on the seat (mode 1) stays there when a link opens
/// one of its panes, and whether the person's front app keeps the focus meanwhile. Every app activation
/// during each step is counted, so a focus taken and given back is seen too. Gated by
/// BRAUS_MAC_LIVE_TESTS=1: it opens System Settings, which the person sees in the Dock. It only opens
/// panes; it presses nothing in them. It quits System Settings only when it launched it.
@Suite("Mac launch probe: a pane link while the app is on the seat", .serialized)
struct MacLaunchProbeLiveTests {

    static let settings = "com.apple.systempreferences"
    static let panes = ["com.apple.Sound-Settings.extension", "com.apple.Keyboard-Settings.extension"]

    @Test("open panes by link with System Settings on the seat",
          .enabled(if: ProcessInfo.processInfo.environment["BRAUS_MAC_LIVE_TESTS"] == "1"))
    @MainActor
    func paneLinkOnSeat() async throws {
        let front = NSWorkspace.shared.frontmostApplication
        Self.log("front at start", front?.bundleIdentifier ?? "none")
        let activations = ActivationCounter()

        var launched = false
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.settings).isEmpty {
            let url = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.settings))
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            launched = true
            try await Self.waitForWindow()
            Self.log("launch activates=false", "activations \(activations.take()), front "
                     + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"))
        }
        defer {
            if launched { NSRunningApplication.runningApplications(withBundleIdentifier: Self.settings).first?.terminate() }
        }

        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("mac-probe-\(UUID().uuidString)")
        let session = BrokeredAutomationSession(broker: SeatBroker(), workerID: UUID(), knowledgeDirectory: knowledge)
        let opened = try await session.open(application: Self.settings, window: nil)
        Self.log("open_session", "window \"\(opened.windowTitle)\", frame \(Self.frames()), activations \(activations.take()), "
                 + "front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        let seatFrames = Self.frames()

        for pane in Self.panes {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let link = try #require(URL(string: "x-apple.systempreferences:\(pane)"))
            _ = try await NSWorkspace.shared.open(link, configuration: configuration)
            try await Task.sleep(for: .seconds(2))
            let scene = try await session.observe()
            Self.log("link \(pane)", "window \"\(scene.windowTitle)\", frame \(Self.frames()) "
                     + "(seat \(seatFrames)), activations \(activations.take()), front "
                     + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"))
            Self.log("scene head", String(scene.text().split(separator: "\n").prefix(14).joined(separator: " | ")))
        }
        await session.close()
        Self.log("after close", "frame \(Self.frames()), activations \(activations.take()), front "
                 + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"))
    }

    // MARK: Support

    static func log(_ step: String, _ detail: String) {
        print("PROBE \(step): \(detail)")
    }

    /// System Settings' on-screen windows as `title@x,y wxh`, in window server coordinates.
    @MainActor
    static func frames(of bundleID: String = settings) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let rows = try? WindowServerWindowListing().windows(ownedBy: app.processIdentifier) else { return "none" }
        return rows.filter { $0.layer == 0 }.map { row in
            "\(row.title ?? "")@\(Int(row.frame.minX)),\(Int(row.frame.minY)) \(Int(row.frame.width))x\(Int(row.frame.height))"
        }.joined(separator: "; ")
    }

    @MainActor
    static func waitForWindow() async throws {
        for _ in 0..<50 {
            if frames() != "none", !frames().isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// ActivationCounter lists the apps that became active since the last `take()`.
@MainActor
final class ActivationCounter {
    private var seen: [String] = []
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.bundleIdentifier ?? "?"
            MainActor.assumeIsolated { self?.seen.append(name) }
        }
    }

    func take() -> String {
        defer { seen = [] }
        return seen.isEmpty ? "none" : seen.joined(separator: ", ")
    }
}
