import Foundation

/// MacLauncher opens an application in the background and hands back its first window, leaving the
/// person's app in front.
///
/// It resolves the app by bundle id, path, or name in any of the app's names (English or the
/// person's language), refuses password managers, launches with `activates = false`, and waits for
/// the first window in the accessibility tree. An app that activates itself anyway is let be, then
/// the person's app is brought back, unless the person used the keyboard or mouse since the launch
/// began. A sheet on the first window (a first-run sheet) is reported with its buttons; dismissing it
/// is the agent's choice, with the non-committal button.
public struct MacLauncher: Sendable {

    public let workspace: any MacWorkspace
    public let reader: any MacTreeReading
    /// How long to wait for a first window. Mail, Messages, TextEdit, QuickTime and Automator showed
    /// none within 12 s on 14 Oct.
    public var windowTimeout: Duration
    public var pollInterval: Duration
    /// The launch style when none is asked for: `revert`, which costs nothing when the app stays behind
    /// and catches a flash `plain` lets through (Music, 15 Oct).
    public var defaultStyle: MacLaunchStyle = .revert

    public init(
        workspace    : any MacWorkspace,
        reader       : any MacTreeReading,
        windowTimeout: Duration = .seconds(12),
        pollInterval : Duration = .milliseconds(100)
    ) {
        self.workspace     = workspace
        self.reader        = reader
        self.windowTimeout = windowTimeout
        self.pollInterval  = pollInterval
    }

    /// The installed app a request names: a bundle id, a path to a `.app`, or a name.
    public func resolve(_ request: String) throws -> MacApp {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            guard let app = workspace.application(at: url) else { throw MacLaunchFailure.notFound(request) }
            return app
        }
        if trimmed.contains("."), !trimmed.contains(" "), let app = workspace.application(bundleID: trimmed) {
            return app
        }
        let wanted = Self.folded(trimmed)
        let installed = workspace.installedApplications()
        let exact = installed.filter { $0.names.contains { Self.folded($0) == wanted } }
        if let one = try identity(among: exact, for: request) { return one }
        if let apple = try appleOwn(wanted, among: installed, for: request) { return apple }
        throw MacLaunchFailure.notFound(request)
    }

    /// The one application `matches` are, or nil for none: one bundle identifier is one identity whatever its
    /// paths, taken at the path the workspace names for it when that is among them; several identifiers are an
    /// `ambiguous` refusal naming them, sorted, and nothing is opened.
    private func identity(among matches: [MacApp], for request: String) throws -> MacApp? {
        let identifiers = Set(matches.map(\.bundleID)).sorted()
        guard let only = identifiers.first else { return nil }
        guard identifiers.count == 1 else { throw MacLaunchFailure.ambiguous(request, identifiers) }
        let preferred = workspace.application(bundleID: only)?.url
        return matches.first { $0.url == preferred } ?? matches.first
    }

    /// "Apple <name>": the installed application whose bundle identifier starts with `com.apple.` and one of whose
    /// names is exactly `<name>`, English or the person's language alike. Nil for any other shape or when no Apple
    /// application has that name; never a third party's, never a part of a name; two are ambiguous.
    private func appleOwn(_ wanted: String, among installed: [MacApp], for request: String) throws -> MacApp? {
        let words = wanted.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, words[0] == "apple" else { return nil }
        let rest = words.dropFirst().joined(separator: " ")
        let owned = installed.filter { app in
            app.bundleID.lowercased().hasPrefix("com.apple.") && app.names.contains { Self.folded($0) == rest }
        }
        return try identity(among: owned, for: request)
    }

    /// Opens the app in the background, launched in `style` or `defaultStyle`; see the type's
    /// documentation for the steps.
    public func open(_ request: String, style requested: MacLaunchStyle? = nil) async throws -> MacLaunchReport {
        try await open(try resolve(request), style: requested)
    }

    /// Opens `app`, already resolved: no name is looked up again, so the app opened is the one resolved.
    public func open(_ app: MacApp, style requested: MacLaunchStyle? = nil) async throws -> MacLaunchReport {
        guard !MacRefusedApps.refuses(app) else { throw MacLaunchFailure.refused(app.displayName) }
        guard reader.isTrusted else { throw MacLaunchFailure.notTrusted }

        let guardian = await MacFocusGuard.begin(workspace)
        var running: MacRunningApp
        let wasRunning: Bool
        var reopenRequested = false
        let style = requested ?? defaultStyle
        if let existing = workspace.running(bundleID: app.bundleID) {
            running = existing
            wasRunning = true
            // A running app whose window list reads empty is asked once, in the background, for a window (a launch that
            // does not activate reopens a running app); a failed read, a cancellation or a listed window asks nothing.
            if let listed = try? await reader.windows(of: existing.processID), listed.isEmpty {
                try Task.checkCancellation()
                do { running = try await workspace.launch(app) } catch {
                    _ = await guardian.settle(after: existing.processID, restoring: true)
                    throw error
                }
                reopenRequested = true
            }
        } else {
            running = try await workspace.launch(app, style: style, restoring: guardian.front?.processID)
            wasRunning = false
        }

        let windows: [MacWindowSummary]
        do {
            windows = try await waitForWindows { (try? await reader.windows(of: running.processID)) ?? [] }
        } catch {
            // Cancelled or failed while waiting: the app this open brought forward is given back first, then the error.
            _ = await guardian.settle(after: running.processID, restoring: true)
            throw error
        }
        let dialogInFront = !wasRunning && workspace.takeSparedDialog(of: app.bundleID)
        let focus = await guardian.settle(after: running.processID, restoring: !dialogInFront)
        let reverts = wasRunning ? 0 : workspace.takeReverts(of: app.bundleID)

        let window = windows.first(where: \.isFocused) ?? windows.first(where: \.isMain) ?? windows.first
        let sheet: MacLaunchReport.Sheet? = if let window { await sheet(on: window, of: running.processID) } else { nil }
        return MacLaunchReport(
            app               : app,
            processID         : running.processID,
            wasRunning        : wasRunning,
            window            : window,
            secondsWaited     : focus.elapsed,
            selfActivated     : (!wasRunning || reopenRequested) && focus.selfActivated,
            focusRestored     : focus.focusRestored,
            personActedMeanwhile: focus.personActed,
            sheet             : sheet,
            style             : wasRunning ? nil : style,
            reverts           : reverts,
            dialogInFront     : dialogInFront,
            reopenRequested   : reopenRequested
        )
    }

    /// Polls `list` until it answers some windows or `windowTimeout` passes; answers the last list.
    func waitForWindows(_ list: () async -> [MacWindowSummary]) async throws -> [MacWindowSummary] {
        try await poll { () -> [MacWindowSummary]? in
            let windows = await list()
            return windows.isEmpty ? nil : windows
        } ?? []
    }

    /// Calls `probe` every `pollInterval` until it answers or `windowTimeout` passes.
    func poll<Answer>(_ probe: () async -> Answer?) async throws -> Answer? {
        let clock = ContinuousClock()
        let started = clock.now
        if let answer = await probe() { return answer }
        while clock.now - started < windowTimeout {
            try await Task.sleep(for: pollInterval)
            if let answer = await probe() { return answer }
        }
        return nil
    }

    /// The sheet over a window, if any, with its button titles. A short read: one sheet's buttons
    /// are near the top of the tree.
    private func sheet(on window: MacWindowSummary, of processID: pid_t) async -> MacLaunchReport.Sheet? {
        let limits = MacTreeLimits(elementLimit: 200, depthLimit: 8, deadline: 1)
        guard let read = try? await reader.read(windowAt: window.index, of: processID, limits: limits),
              let sheet = read.window.children.first(where: { $0.role == "AXSheet" })
        else { return nil }
        let texts = sheet.flattened.filter { $0.role == "AXStaticText" }.compactMap(\.value)
        let buttons = sheet.flattened.filter { $0.role == "AXButton" }.compactMap { $0.title ?? $0.descriptionText }
        return MacLaunchReport.Sheet(title: texts.first, buttons: buttons)
    }

    /// Names compared without case, diacritics or a trailing ".app".
    static func folded(_ name: String) -> String {
        var text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if text.hasSuffix(".app") { text.removeLast(4) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// MacLaunchReport says what opening an app did: which process, which window, how long it took,
/// and what happened to the person's front app.
public struct MacLaunchReport: Sendable, Equatable {

    public struct Sheet: Sendable, Equatable {
        /// The sheet's first text, usually its title.
        public var title: String?
        public var buttons: [String]

        public init(title: String?, buttons: [String]) {
            self.title   = title
            self.buttons = buttons
        }
    }

    public var app: MacApp
    public var processID: pid_t
    public var wasRunning: Bool
    /// Nil when no window appeared in time: a document app showing its file panel, Mail before its
    /// viewer. The agent opens a new document or waits.
    public var window: MacWindowSummary?
    public var secondsWaited: Double
    /// The app came to the front by itself although it was launched without activation.
    public var selfActivated: Bool
    /// The person's app is in front again.
    public var focusRestored: Bool
    /// The person typed or clicked during the launch, so their focus was left as they set it.
    public var personActedMeanwhile: Bool
    public var sheet: Sheet?
    /// How the app was launched; nil when it was already running.
    public var style: MacLaunchStyle?
    /// How many times a `revert` launch brought the person's app back.
    public var reverts: Int
    /// The app came forward with a dialog or a sheet, left in front for the person (the seat takes it).
    public var dialogInFront: Bool
    /// The app was running with no window listed and was asked once, in the background, for one; `processID` is
    /// the process that request answered, `window` says whether one came within the wait, and `selfActivated` and
    /// the focus fields say what the request did to the front, as a launch's do.
    public var reopenRequested: Bool

    /// The app's window is in front of the person's: the seat takes it (`MacFocusGuard.leavesInFront`).
    public var leftInFront: Bool {
        MacFocusGuard.leavesInFront(selfActivated: selfActivated, focusRestored: focusRestored,
                                    personActed: personActedMeanwhile)
    }

    public init(
        app                 : MacApp,
        processID           : pid_t,
        wasRunning          : Bool,
        window              : MacWindowSummary?,
        secondsWaited       : Double,
        selfActivated       : Bool,
        focusRestored       : Bool,
        personActedMeanwhile: Bool,
        sheet               : Sheet?,
        style               : MacLaunchStyle? = nil,
        reverts             : Int = 0,
        dialogInFront       : Bool = false,
        reopenRequested     : Bool = false
    ) {
        self.style                = style
        self.reverts              = reverts
        self.dialogInFront        = dialogInFront
        self.reopenRequested      = reopenRequested
        self.app                  = app
        self.processID            = processID
        self.wasRunning           = wasRunning
        self.window               = window
        self.secondsWaited        = secondsWaited
        self.selfActivated        = selfActivated
        self.focusRestored        = focusRestored
        self.personActedMeanwhile = personActedMeanwhile
        self.sheet                = sheet
    }
}

public enum MacLaunchFailure: Error, Equatable, Sendable {
    case notFound(String)
    /// The request names more than one installed application: their bundle identifiers, sorted. Nothing was opened.
    case ambiguous(String, [String])
    /// A password manager: Braus never drives one.
    case refused(String)
    /// Braus has no accessibility permission, so it could not see the window.
    case notTrusted
}
