import AppKit
import EngineCore
import Foundation
import MacDriver
import PerceptionCore
import SeatCore

/// MacScenes fills `SceneProviding` from the accessibility tree: a fresh read of the process's
/// window at every call, with the app behind. No pixels, no seat.
///
/// The window is the focused one, else the main one, else the first that is not minimized, never the
/// system's window sharing indicator (`WindowSharingIndicator`).
public struct MacScenes: SceneProviding {

    public let reader: any MacTreeReading
    public let limits: MacTreeLimits
    /// Where each read is kept for `MacActuator`; nil when nothing acts on these scenes.
    public let cache: MacSceneCache?
    public let serverWindows: MacWindows.ServerWindows
    /// Who the process is, for the scene's bundle identifier and app name: the workspace's answer for a live
    /// process (`liveIdentity`), or what a test's fake process is declared to be.
    public let identity: ProcessIdentity

    /// The bundle identifier and name of a process; empty when the workspace knows no application behind it.
    public typealias ProcessIdentity = @Sendable (pid_t) async -> (bundleID: String, name: String)

    public init(
        reader       : any MacTreeReading = LiveMacTreeReader(),
        limits       : MacTreeLimits = .standard,
        cache        : MacSceneCache? = nil,
        serverWindows: @escaping MacWindows.ServerWindows = MacWindows.liveServerWindows,
        identity     : @escaping ProcessIdentity = MacScenes.liveIdentity
    ) {
        self.reader        = reader
        self.limits        = limits
        self.cache         = cache
        self.serverWindows = serverWindows
        self.identity      = identity
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        try await scene(of: processID).perceived
    }

    /// The scene with its coverage and the cost of the read.
    public func scene(of processID: pid_t) async throws -> MacScene {
        let (window, read, readAt) = try await Self.read(by: reader, processID, limits)
        if let cache {
            let number = window.frame.flatMap { frame in
                serverWindows(processID).first { MacWindows.sameFrame($0.frame, frame) }?.number
            } ?? 0
            cache.store(MacSceneCache.Entry(window: read.window, windowIndex: window.index, windowNumber: number,
                                            readAt: readAt, windowIdentity: read.windowIdentity),
                        for: processID)
        }
        let identity = await identity(processID)
        return MacSceneBuilder.scene(
            from            : read,
            bundleID        : identity.bundleID,
            appName         : identity.name,
            isGrantAvailable: reader.isTrusted
        )
    }

    /// The window list and the tree read block until the app answers or their timeouts pass; they run
    /// off the caller's actor (spec section 3, rule 3).
    @concurrent
    static func read(
        by reader: any MacTreeReading, _ processID: pid_t, _ limits: MacTreeLimits
    ) async throws -> (MacWindowSummary, MacTreeRead, ContinuousClock.Instant) {
        var windows = try await reader.windows(of: processID).filter { !$0.isMinimized }
        while let window = windows.first(where: \.isFocused) ?? windows.first(where: \.isMain) ?? windows.first {
            let readAt = ContinuousClock.now
            let read = try await reader.read(windowAt: window.index, of: processID, limits: limits)
            // The system's window sharing indicator is no window of the application: the next one is read.
            guard WindowSharingIndicator.matches(
                subrole : read.window.subrole,
                isModal : nil,
                children: { read.window.children.map { (role: $0.role as String?, title: $0.title) } }
            ) else { return (window, read, readAt) }
            windows.removeAll { $0.index == window.index }
        }
        throw MacTreeFailure.windowNotFound(index: 0)
    }

    /// The live answer: the running application the workspace knows for the process, or nothing.
    public static func liveIdentity(of processID: pid_t) async -> (bundleID: String, name: String) {
        await MainActor.run {
            let application = NSRunningApplication(processIdentifier: processID)
            return (application?.bundleIdentifier ?? "", application?.localizedName ?? "")
        }
    }
}
