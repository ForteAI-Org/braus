//
//  ChromeProfilesSettings.swift
//  Braus
//

import AppKit
import AutomationRuntime
import ChromeProfiles
import Foundation
import Observation

/// ChromeProfilesSettings is what Settings, Chrome Profiles shows and does to connect the person's Chrome to
/// Braus with one button, Connect Chrome, and no Terminal, file or address of their own:
/// - it turns web pages on for the next launch when they are off, keeping every other channel, and then offers a
///   restart that waits for no worker: it refuses while one is answering;
/// - it prepares a folder of the extension the app carries (`ExtensionFolder`) and registers Braus's host with
///   every Chrome this Mac has (`NativeHostRegistration`), never over a file Braus did not write;
/// - it opens Chrome's Extensions page and shows the prepared extension folder selected in Finder, and then each
///   profile once it is paired and connected.
///
/// What only the person can do stays theirs, in Chrome, in each profile: turning on Developer mode, adding the
/// folder (dragged onto the Extensions page, or with Load unpacked), allowing the extension, and naming the profile
/// on the pairing page it opens. The extension is not published in the Chrome Web Store, which this does not need.
///
/// Reading the state writes nothing. The Advanced controls do each step on its own.
@Observable
@MainActor
final class ChromeProfilesSettings {

    /// Whether this run reaches web pages, which the hub and the pairing need.
    enum WebPages: Equatable {
        /// This run composes the web.
        case on
        /// Turned on for the next launch; this run does not compose it.
        case onAfterRestart
        case off
        /// An isolated run composes no channel.
        case isolated
        /// The stored channels do not parse: Braus does not rewrite them.
        case unreadable(String)
    }

    /// Where Connect Chrome stands, which the page's main section shows.
    enum Stage: Equatable {
        /// This run connects nothing.
        case isolated
        /// Something is not set up yet: Connect Chrome does it.
        case notConnected
        /// Set up; web pages need Braus to open again.
        case restartNeeded
        /// Set up and running: the person adds the extension in Chrome.
        case addExtension
        /// Profiles are paired, and none is connected now.
        case profilesNotConnected
        /// At least one paired profile is connected now.
        case ready
    }

    /// One Chrome this Mac has, with its registration of Braus's host.
    struct Browser: Identifiable {
        let browser: ChromeBrowser
        var state  : NativeHostRegistration.State
        var id: String { browser.id }
    }

    private(set) var webPages: WebPages = .off
    private(set) var browsers: [Browser] = []
    private(set) var extensionFolder: ExtensionFolder.State = .notPrepared
    private(set) var profiles: [ChromeProfile] = []
    /// What the last action could not do, in the person's words; nil once another succeeds.
    private(set) var problem: String?

    /// Whether a worker is answering, or an external client is busy, now: a restart waits for none of them.
    /// The app gives it once its delegate holds the teams.
    var isBusy: @MainActor () -> Bool = { false }

    /// Where the extension is prepared for the person to add in Chrome, under the name the page uses for it: Braus's
    /// own folder, never the app bundle, which Chrome's folder picker does not open and which a new version of the
    /// app replaces.
    let extensionFolderURL = WorkspaceLaunch.directory.appending(path: "Braus for Chrome", directoryHint: .isDirectory)

    private let hub: ChromeProfileHub?

    /// True once the person pressed Connect Chrome in this run: a Chrome that appears afterwards (opened for the
    /// first time) is registered as the page reads it again.
    private var isConnecting = false

    init(hub: ChromeProfileHub?) {
        self.hub = hub
        // The hub reports from its own threads: the list changes on the main actor.
        hub?.observe { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.profiles = self.hub?.profiles ?? []
            }
        }
    }

    // MARK: Reading

    var stage: Stage {
        switch webPages {
            case .isolated        : return .isolated
            case .off, .unreadable: return .notConnected
            case .onAfterRestart  : return isSetUp ? .restartNeeded : .notConnected
            case .on:
                // Ready only from the hub: a paired profile connected now, never from what Braus prepared.
                if profiles.contains(where: \.isConnected) { return .ready }
                if !profiles.isEmpty { return .profilesNotConnected }
                return isSetUp ? .addExtension : .notConnected
        }
    }

    /// The extension folder is current and at least one Chrome has Braus's host.
    private var isSetUp: Bool {
        extensionFolder == .current && browsers.contains { $0.state == .registered }
    }

    /// Reads every state again, and, once the person pressed Connect Chrome, registers a Chrome that appeared
    /// since. Writes nothing otherwise.
    func refresh() {
        read()
        if isConnecting, browsers.contains(where: { $0.state == .notRegistered || isElsewhere($0.state) }) {
            registerAll()
            read()
        }
    }

    private func read() {
        webPages        = Self.webPages()
        profiles        = hub?.profiles ?? []
        extensionFolder = folder.state()
        let support     = ChromeBrowser.supportDirectory(environment: ProcessInfo.processInfo.environment)
        browsers = ChromeBrowser.known.compactMap { browser in
            let state = registration(for: browser, under: support).state()
            // Google Chrome always; another Chrome only once this Mac has it.
            guard browser == .googleChrome || state != .browserNotFound
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil
            else { return nil }
            return Browser(browser: browser, state: state)
        }
    }

    private static func webPages() -> WebPages {
        if LaunchIsolation.current.isIsolated { return .isolated }
        if AppModel.launchChannels.contains(.web) { return .on }
        let stored = UserDefaults.standard.string(forKey: AppPreferences.channels) ?? AppPreferences.channelsDefault
        guard let channels = try? AutomationChannels(parsing: stored) else { return .unreadable(stored) }
        return channels.contains(.web) ? .onAfterRestart : .off
    }

    // MARK: Connect Chrome

    /// Sets Braus up for Chrome in one go, then, when web pages need no restart, opens Chrome's Extensions page with
    /// the extension folder selected in Finder. Each part that cannot be done is said, and the rest goes on.
    func connectChrome() {
        isConnecting = true
        read()
        var problems: [String] = []
        if webPages == .off, let failure = storeWebPages() { problems.append(failure) }
        if case .unreadable(let stored) = webPages {
            problems.append("Braus cannot read its stored routes (“\(stored)”) and leaves them as they are.")
        }
        if folder.state() != .current {
            do { try folder.prepare() } catch { problems.append(String(describing: error)) }
        }
        read()
        problems += registerAll()
        // What the registrations just wrote decides the rest: a Chrome registered now is never followed by opening
        // another one for the first time.
        read()
        if !browsers.contains(where: { $0.state == .registered }),
           let chrome = browsers.first(where: { $0.state == .browserNotFound && isInstalled($0.browser) }) {
            // A Chrome that never ran has no folder to register in: opened once, it makes one, and the page
            // registers it when the person comes back.
            open(chrome.browser)
            problems.append("\(chrome.browser.name) opened for the first time: come back here once it is open.")
        } else if !browsers.contains(where: { isInstalled($0.browser) }) {
            problems.append("Google Chrome is not installed on this Mac.")
        }
        read()
        problem = problems.isEmpty ? nil : problems.joined(separator: "\n")
        if stage == .addExtension { openExtensionsPage() }
    }

    /// Shows the extension folder selected in Finder and opens Chrome's Extensions page in a Chrome connected to
    /// Braus, where the person adds the folder. Nothing is clicked, turned on or allowed for them.
    func openExtensionsPage() {
        if extensionFolder == .current { revealExtensionFolder() }
        guard let page = URL(string: "chrome://extensions") else { return }
        open(page, inConnected: "Chrome's Extensions page")
    }

    /// Opens a Chrome connected to Braus, where paired profiles connect again. Nothing is opened in it.
    func openConnectedChrome() {
        guard let chrome = connectedChrome else {
            problem = "No Chrome connected to Braus is installed on this Mac."
            return
        }
        open(chrome)
    }

    /// Opens Braus again so web pages apply, once no worker is answering and no client is busy, never two at once:
    /// it checks and quits in one step on the main actor, so no turn starts in between; the quit writes what is
    /// typed and gives every seat back, as Quit does; and a waiter opens Braus only once this process has ended,
    /// with this run's Braus settings and arguments, or gives up after a minute if it has not.
    func restartBraus() {
        problem = Self.restartBraus(unless: isBusy)
    }

    /// Restarts Braus as `restartBraus` describes, unless `isBusy`: what stopped it, or nil once it quits. Settings'
    static func restartBraus(unless isBusy: @MainActor () -> Bool) -> String? {
        guard !isBusy() else {
            return "A worker is answering, or a client is using Braus: restart once it is done or stopped."
        }
        var arguments = [Self.relaunchScript, "braus-relaunch", String(getpid())]
        for (name, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key })
        where name.hasPrefix("BRAUS_") {
            arguments += ["--env", "\(name)=\(value)"]
        }
        arguments.append(Bundle.main.bundleURL.path(percentEncoded: false))
        let passed = Array(CommandLine.arguments.dropFirst())
        if !passed.isEmpty { arguments += ["--args"] + passed }
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments     = ["-c"] + arguments
        do { try waiter.run() } catch {
            return "Braus could not prepare its restart: \(error.localizedDescription)"
        }
        NSApp.terminate(nil)
        return nil
    }

    /// Waits for the process `$1` to end, for up to a minute, then opens Braus with the rest of its arguments.
    static let relaunchScript = """
        pid="$1"; shift
        tries=0
        while kill -0 "$pid" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -le 300 ] || exit 0
            sleep 0.2
        done
        exec /usr/bin/open -n "$@"
        """

    // MARK: Advanced, each step on its own

    /// Turns web pages on from the next launch, keeping every other channel stored. This run stays as it is:
    /// no worker changes its route while it runs.
    func turnOnWebPages() {
        problem = storeWebPages()
        read()
    }

    /// Registers Braus's host with `browser`, or updates a registration of Braus's that names another copy.
    func register(_ browser: ChromeBrowser) {
        act { try self.register(browser, under: self.support) }
    }

    /// Removes Braus's registration from `browser`; a file Braus did not write stays. It also ends Connect
    /// Chrome's set-up in this run, so reading the page again never registers it back: only Connect Chrome,
    /// pressed again, does.
    func unregister(_ browser: ChromeBrowser) {
        isConnecting = false
        act { try self.registration(for: browser, under: self.support).unregister() }
    }

    /// Copies the extension the app carries into `extensionFolderURL`, or brings an earlier copy up to date.
    func prepareExtensionFolder() {
        act { try self.folder.prepare() }
    }

    func revealExtensionFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolderURL])
    }

    /// Opens `browser`, so the person can go on there. Nothing is opened in it.
    func open(_ browser: ChromeBrowser) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            problem = "\(browser.name) is not installed on this Mac."
            return
        }
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Private

    private var support: URL { ChromeBrowser.supportDirectory(environment: ProcessInfo.processInfo.environment) }

    private var folder: ExtensionFolder {
        ExtensionFolder(
            source     : Bundle.main.resourceURL?.appending(path: "ChromeExtension", directoryHint: .isDirectory)
                ?? Bundle.main.bundleURL,
            destination: extensionFolderURL
        )
    }

    /// The host the app carries.
    private var hostPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/braus-chrome-host").path(percentEncoded: false)
    }

    /// The hub's socket in this run.
    private var socketPath: String {
        hub?.socketPath
            ?? WorkspaceLaunch.directory.appending(path: "ChromeProfiles/hub.sock").path(percentEncoded: false)
    }

    /// The registration of Braus's host in `browser`. The manifest names the host the app carries or, when this
    /// run keeps its hub elsewhere than the host's default (`BRAUS_APP_SUPPORT_DIR`), the launcher that passes the
    /// hub's socket, which only a registration writes.
    private func registration(for browser: ChromeBrowser, under support: URL) -> NativeHostRegistration {
        NativeHostRegistration(userDataDirectory: browser.userDataDirectory(under: support),
                               hostPath: HostLauncher.path(host: hostPath, socket: socketPath))
    }

    private func register(_ browser: ChromeBrowser, under support: URL) throws {
        try HostLauncher.prepare(host: hostPath, socket: socketPath)
        try registration(for: browser, under: support).register()
    }

    /// Registers every Chrome that has a folder and no registration of Braus's for this copy; one left as it is
    /// (a file Braus did not write) is said. Returns what could not be done.
    @discardableResult
    private func registerAll() -> [String] {
        var problems: [String] = []
        for row in browsers where row.state == .notRegistered || isElsewhere(row.state) {
            do { try register(row.browser, under: support) } catch {
                problems.append("\(row.browser.name): \(error)")
            }
        }
        for row in browsers {
            if case .foreign(let reason) = row.state {
                problems.append("\(row.browser.name): Braus left its registration as it is, \(reason).")
            }
        }
        return problems
    }

    private func isElsewhere(_ state: NativeHostRegistration.State) -> Bool {
        if case .registeredElsewhere = state { return true }
        return false
    }

    /// The first Chrome with Braus's host that is installed.
    private var connectedChrome: ChromeBrowser? {
        browsers.first { $0.state == .registered && isInstalled($0.browser) }?.browser
    }

    private func open(_ url: URL, inConnected place: String) {
        guard let chrome = connectedChrome,
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chrome.bundleID) else {
            problem = "No Chrome connected to Braus is installed on this Mac."
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in self.problem = "\(place) did not open in \(chrome.name): \(error.localizedDescription)" }
        }
    }

    private func isInstalled(_ browser: ChromeBrowser) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) != nil
    }

    /// Stores web pages on, keeping the other channels; what could not be done, or nil.
    private func storeWebPages() -> String? {
        Self.store(.web)
    }

    /// Stores `channel` on for the next launch, keeping every other channel stored; a stored value that does not
    /// read as channels is left as it is. What could not be done, or nil.
    static func store(_ channel: AutomationChannels) -> String? {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: AppPreferences.channels) ?? AppPreferences.channelsDefault
        guard var channels = try? AutomationChannels(parsing: stored) else {
            return "Braus did not change its routes: the stored value “\(stored)” does not read as a list of them."
        }
        channels.insert(channel)
        defaults.set(channels.description, forKey: AppPreferences.channels)
        return nil
    }

    private func act(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = String(describing: error)
        }
        read()
    }
}
