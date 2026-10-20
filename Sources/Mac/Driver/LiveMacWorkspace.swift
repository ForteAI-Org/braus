import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// LiveMacWorkspace fills `MacWorkspace` with AppKit's workspace and the HID event state.
public struct LiveMacWorkspace: MacWorkspace {

    /// The folders searched for installed applications, one level deep (Finder lives in CoreServices).
    public let folders: [URL]

    /// The person's languages in their order (`Locale.preferredLanguages`): an app's names are read in each of them
    /// the app localizes, the first first.
    public let preferredLanguages: [String]

    public init(folders: [URL]? = nil, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.preferredLanguages = preferredLanguages
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.folders = folders ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            home.appendingPathComponent("Applications"),
        ]
    }

    public func installedApplications() -> [MacApp] {
        let files = FileManager.default
        return folders.flatMap { folder -> [MacApp] in
            let entries = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return entries.filter { $0.pathExtension == "app" }.compactMap(application(at:))
        }
    }

    public func application(bundleID: String) -> MacApp? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(application(at:))
    }

    public func application(at url: URL) -> MacApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let localized = bundle.localizedInfoDictionary ?? [:]
        var candidates: [String?] = BundleNames.names(of: bundle, for: preferredLanguages)
        candidates += [
            FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            localized["CFBundleDisplayName"] as? String,
            localized["CFBundleName"] as? String,
            info["CFBundleDisplayName"] as? String,
            info["CFBundleName"] as? String,
            url.deletingPathExtension().lastPathComponent,
        ]
        var names: [String] = []
        for case let name? in candidates where !name.isEmpty && !names.contains(name) { names.append(name) }
        return MacApp(bundleID: bundleID, url: url, names: names)
    }

    public func running(bundleID: String) -> MacRunningApp? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }
            .map(Self.running)
    }

    public func frontmost() async -> MacRunningApp? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication.map(Self.running) }
    }

    public func launch(_ app: MacApp) async throws -> MacRunningApp {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let launched = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
        return Self.running(launched)
    }

    public func launch(_ app: MacApp, style: MacLaunchStyle, restoring front: pid_t?) async throws -> MacRunningApp {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let watch = style == .revert ? front.map { Self.revert(app.bundleID, to: $0, for: .seconds(4)) } : nil
        do {
            let launched = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
            return Self.running(launched)
        } catch {
            watch?.cancel()
            throw error
        }
    }

    public func takeReverts(of bundleID: String) -> Int {
        Self.reverts.withLock { $0.removeValue(forKey: bundleID) ?? 0 }
    }

    public func takeSparedDialog(of bundleID: String) -> Bool {
        Self.sparedDialogs.withLock { $0.remove(bundleID) != nil }
    }

    public func watchFront(of bundleID: String, restoring front: pid_t?) {
        guard let front else { return }
        _ = Self.revert(bundleID, to: front, for: .seconds(4))
    }

    private static let reverts = Mutex<[String: Int]>([:])
    private static let sparedDialogs = Mutex<Set<String>>([])

    /// Watches the front window and the active app every 5 ms for `duration`, off the main actor: when
    /// `bundleID` owns the top window or is the active app and the person has not
    /// used the keyboard or mouse since the watch began, `front` is brought back at once. Each time it
    /// does, the watch runs `duration` longer, up to `limit`: Figma took the front three times in 4 s
    /// and again after (15 Oct).
    private static func revert(_ bundleID: String, to front: pid_t, for duration: Duration,
                               limit: Duration = .seconds(15)) -> Task<Void, Never> {
        Task.detached {
            let clock = ContinuousClock()
            let started = clock.now
            var end = clock.now.advanced(by: duration)
            while clock.now < end, !Task.isCancelled {
                // The top window's owner, or the active app: Phone activated 0.8 s before its window
                // showed (15 Oct). `frontmostApplication` is read off the main actor, as the list is.
                let candidates = [frontWindowOwner(), NSWorkspace.shared.frontmostApplication?.processIdentifier]
                if let owner = candidates.compactMap({ $0 }).first(where: { pid in
                       pid != front && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
                   }) {
                    let watched = clock.now - started
                    let sinceInput = LiveMacWorkspace().secondsSincePersonInput()
                    guard sinceInput > Double(watched.components.seconds) + Double(watched.components.attoseconds) / 1e18 else { return }
                    // The person's app first: every millisecond before it is a flash on their screen.
                    await MainActor.run { _ = NSRunningApplication(processIdentifier: front)?.activate() }
                    // A dialog or a sheet (a login, a permission prompt) is what the app came forward to
                    // show: it gets the front back, the watch ends, and the launcher hands the app to the seat.
                    if showsDialog(owner) {
                        await MainActor.run { _ = NSRunningApplication(processIdentifier: owner)?.activate() }
                        sparedDialogs.withLock { _ = $0.insert(bundleID) }
                        return
                    }
                    reverts.withLock { $0[bundleID, default: 0] += 1 }
                    end = min(clock.now.advanced(by: duration), started.advanced(by: limit))
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Whether the app's focused window is a dialog or carries a sheet. Two attribute reads and the
    /// window's children, each with a 0.1 s messaging timeout, off the main actor like the watch. It runs
    /// after the person's app is back, so it adds no time to the flash.
    static func showsDialog(_ processID: pid_t) -> Bool {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, 0.1)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        guard let focused = attribute(AXUIElementCreateApplication(processID), kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = focused as! AXUIElement
        if let subrole = attribute(window, kAXSubroleAttribute) as? String, ["AXDialog", "AXSystemDialog"].contains(subrole) {
            return true
        }
        let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.contains { (attribute($0, kAXRoleAttribute) as? String) == "AXSheet" }
    }

    /// The process that owns the frontmost ordinary window, from the window server's list.
    public static func frontWindowOwner() -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let window = list.first { info in
            (info[kCGWindowLayer as String] as? Int) == 0 && ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0
        }
        return (window?[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
    }

    public func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let opened = try await NSWorkspace.shared.open(items, withApplicationAt: app.url, configuration: configuration)
        return Self.running(opened)
    }

    public func openLink(_ link: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.open(link, configuration: configuration)
    }

    public func defaultApplication(for item: URL) -> MacApp? {
        NSWorkspace.shared.urlForApplication(toOpen: item).flatMap(application(at:))
    }

    public func activate(_ processID: pid_t) async {
        await MainActor.run { _ = NSRunningApplication(processIdentifier: processID)?.activate() }
    }

    public func secondsSincePersonInput() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    /// The bundle's names in the first of the person's languages it localizes (`BundleNames`).
    static func namesInPreferredLanguage(of bundle: Bundle) -> [String: String] {
        BundleNames.tables(of: bundle, for: Locale.preferredLanguages).first ?? [:]
    }

    private static func running(_ application: NSRunningApplication) -> MacRunningApp {
        MacRunningApp(
            processID: application.processIdentifier,
            bundleID : application.bundleIdentifier,
            name     : application.localizedName
        )
    }
}
