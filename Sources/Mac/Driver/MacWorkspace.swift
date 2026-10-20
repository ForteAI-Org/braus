import Foundation

/// MacApp is an installed application: its bundle, and every name a person or an agent may use for it
/// (the file name, the bundle's names, the name Finder shows in the person's language).
public struct MacApp: Sendable, Equatable {

    public var bundleID: String
    public var url: URL
    /// The first is the name Finder shows; the rest are other names it answers to.
    public var names: [String]

    public init(bundleID: String, url: URL, names: [String]) {
        self.bundleID = bundleID
        self.url      = url
        self.names    = names
    }

    public var displayName: String { names.first ?? bundleID }
}

/// MacRunningApp is a running process of an application.
public struct MacRunningApp: Sendable, Equatable {

    public var processID: pid_t
    public var bundleID: String?
    public var name: String?

    public init(processID: pid_t, bundleID: String? = nil, name: String? = nil) {
        self.processID = processID
        self.bundleID  = bundleID
        self.name      = name
    }
}

/// MacLaunchStyle is how a launch keeps the person's app in front when the launched app activates
/// itself anyway (Settings, Music and others did, 15 Oct, #51).
public enum MacLaunchStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// `activates = false` only; the focus guard brings the person's app back once the first window shows.
    case plain
    /// `activates = false`, and the front window watched every 5 ms during the launch: the person's
    /// app is brought back the moment the launched app's window comes in front, unless that window is a
    /// dialog or carries a sheet (a login, a permission prompt): it stays, and the seat takes the app. The default: on
    /// 15 Oct Music came in front 1 launch in 2 in `plain` and 0 in 4 in `revert`, judged by eye, a
    /// flash too short for 10 to 30 ms sampling to record.
    case revert
}

/// MacWorkspace is what `MacLauncher` needs from the system: the installed and running applications,
/// a launch that does not activate, and how long ago the person last used the keyboard or the mouse.
public protocol MacWorkspace: Sendable {

    /// Every application installed in the standard folders.
    func installedApplications() -> [MacApp]

    func application(bundleID: String) -> MacApp?

    func application(at url: URL) -> MacApp?

    func running(bundleID: String) -> MacRunningApp?

    func frontmost() async -> MacRunningApp?

    /// Launches with `activates = false`; returns once the process exists. An app may still
    /// activate itself afterwards (FaceTime, Phone, System Information, Safari, measured).
    func launch(_ app: MacApp) async throws -> MacRunningApp

    /// Opens files or folders with an app, with `activates = false`; launches the app if needed.
    func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp

    /// Opens a link (`x-apple.systempreferences:`) with `activates = false`.
    func openLink(_ link: URL) async throws

    /// The app the system opens this file with.
    func defaultApplication(for item: URL) -> MacApp?

    /// Brings a running app in front. Used only to give the person back the app they had.
    func activate(_ processID: pid_t) async

    /// Seconds since the last keyboard or mouse event from the hardware. Events Braus posts to a
    /// process do not count.
    func secondsSincePersonInput() -> TimeInterval

    /// Launches in a style; `front` is the person's app a `revert` launch brings back.
    func launch(_ app: MacApp, style: MacLaunchStyle, restoring front: pid_t?) async throws -> MacRunningApp

    /// How many times a `revert` launch of the app brought the person's app back, since the last take.
    func takeReverts(of bundleID: String) -> Int

    /// Whether a `revert` launch of the app left it in front because its front window was a dialog or a
    /// sheet, since the last take.
    func takeSparedDialog(of bundleID: String) -> Bool

    /// Starts the `revert` watch for an app about to be opened another way (a file, a link).
    func watchFront(of bundleID: String, restoring front: pid_t?)
}

extension MacWorkspace {
    public func launch(_ app: MacApp, style: MacLaunchStyle, restoring front: pid_t?) async throws -> MacRunningApp {
        try await launch(app)
    }
    public func takeReverts(of bundleID: String) -> Int { 0 }
    public func takeSparedDialog(of bundleID: String) -> Bool { false }
    public func watchFront(of bundleID: String, restoring front: pid_t?) {}
}
