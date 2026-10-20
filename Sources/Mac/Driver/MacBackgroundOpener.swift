import Foundation

/// MacBackgroundOpener runs the operations that open something in another app, with that app behind:
/// a System Settings pane, a file revealed in Finder, a file opened with an app. Each one opens
/// without activation, reads its effect back from the accessibility tree, and gives the person's app
/// back if the other app took the front by itself.
///
/// None uses `NSWorkspace.selectFile` or `activateFileViewerSelecting`: they activate Finder
/// (measured 14 Oct). Finder's scripted `reveal` does not (15 Oct). A window that appears on the person's screen is reported with its frame; moving
/// it to the seat is the session's choice, not the opener's.
public struct MacBackgroundOpener: Sendable {

    public static let settingsBundleID = "com.apple.systempreferences"
    public static let finderBundleID   = "com.apple.finder"

    public let launcher: MacLauncher
    public let finder: any MacFinderScripting
    public let actor: any MacAccessibilityActing

    public init(
        launcher: MacLauncher,
        finder  : any MacFinderScripting = LiveFinderScripting(),
        actor   : any MacAccessibilityActing = LiveMacTreeReader()
    ) {
        self.launcher = launcher
        self.finder   = finder
        self.actor    = actor
    }

    var workspace: any MacWorkspace { launcher.workspace }
    var reader: any MacTreeReading { launcher.reader }

    /// A whole-window read for lookups and read-backs: every child, not only the visible ones.
    static let fullRead = MacTreeLimits(elementLimit: 1_500, deadline: 3, visibleOnly: false)

    // MARK: Settings

    /// Shows a System Settings pane, named by its extension id (`com.apple.Keyboard-Settings.extension`)
    /// or by its name in the sidebar ("Tastiera"). Read back: the sidebar row selected is the pane's.
    public func openSettingsPane(_ request: String) async throws -> MacOpenReport {
        guard reader.isTrusted else { throw MacLaunchFailure.notTrusted }
        guard let settings = workspace.application(bundleID: Self.settingsBundleID) else {
            throw MacLaunchFailure.notFound("System Settings")
        }
        let paneID = try await paneID(for: request)
        guard let link = URL(string: "x-apple.systempreferences:\(paneID)") else {
            throw MacOpenFailure.paneNotFound(request)
        }

        let guardian = await MacFocusGuard.begin(workspace)
        workspace.watchFront(of: Self.settingsBundleID, restoring: guardian.front?.processID)
        try await workspace.openLink(link)
        var processID: pid_t?
        let shown = try await launcher.poll { () -> MacWindowSummary? in
            guard let running = workspace.running(bundleID: Self.settingsBundleID) else { return nil }
            processID = running.processID
            guard let window = await focusedWindow(of: running.processID),
                  let read = try? await reader.read(windowAt: window.index, of: running.processID, limits: Self.fullRead),
                  MacSettingsPane.panes(in: read.window).contains(where: { $0.isSelected && $0.linkID == paneID })
            else { return nil }
            return window
        }
        guard let processID else { throw MacOpenFailure.didNotOpen("System Settings") }
        let focus = await guardian.settle(after: processID)
        let window: MacWindowSummary? = if let shown { shown } else { await focusedWindow(of: processID) }
        return MacOpenReport(
            operation: "settings pane \(paneID)", route: "link: x-apple.systempreferences", app: settings, processID: processID, window: window,
            reason   : shown == nil ? "the selected sidebar row is not \(paneID)" : nil, focus: focus
        )
    }

    /// The pane id a request names. A request with a dot is an id already; a name is looked up in the
    /// sidebar, which needs System Settings open (opened in the background if it is not). The sidebar
    /// holds only the rows it draws (measured 15 Oct), so it is paged down, then up (its scroll bar's
    /// value: it refuses `AXScrollDownByPage`; no focus) until the name shows or the rows stop changing.
    func paneID(for request: String) async throws -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("."), !trimmed.contains(" ") { return trimmed }
        let opened = try await launcher.open(Self.settingsBundleID)
        guard let window = opened.window else { throw MacOpenFailure.didNotOpen("System Settings") }
        let wanted = MacLauncher.folded(trimmed)
        func readPanes() async -> (MacTreeNode, [MacSettingsPane])? {
            guard let read = try? await reader.read(windowAt: window.index, of: opened.processID, limits: Self.fullRead) else { return nil }
            return (read.window, MacSettingsPane.panes(in: read.window))
        }
        // After a cold launch the sidebar fills a moment after the window shows.
        guard var (tree, panes) = try await launcher.poll({ () -> (MacTreeNode, [MacSettingsPane])? in
            guard let found = await readPanes(), !found.1.isEmpty else { return nil }
            return found
        }) else { throw MacOpenFailure.didNotOpen("System Settings") }

        for direction in [MacScrollDirection.down, .up] {
            for _ in 0..<Self.sidebarPages {
                if let pane = panes.first(where: { MacLauncher.folded($0.name) == wanted }) { return pane.linkID }
                guard let first = panes.first,
                      let area = MacTreeLookup.ancestry(in: tree, where: { $0.path == first.path })?
                        .last(where: { $0.role == "AXScrollArea" })
                else { break }
                _ = try? await actor.scroll(MacElementAddress(
                    processID: opened.processID, windowIndex: window.index, path: area.path, role: area.role, visibleOnly: false
                ), direction)
                try await Task.sleep(for: launcher.pollInterval * 3)
                guard let next = await readPanes(), next.1.map(\.id) != panes.map(\.id) else { break }
                (tree, panes) = next
            }
        }
        if let pane = panes.first(where: { MacLauncher.folded($0.name) == wanted }) { return pane.linkID }
        throw MacOpenFailure.paneNotFound(request)
    }

    /// Pages of the sidebar looked through for a pane's name.
    static let sidebarPages = 8

    // MARK: Files

    /// Shows a file or folder selected in a Finder window of its enclosing folder, Finder behind.
    ///
    /// Rung 0, when Braus may already script Finder: Finder's `reveal`, read back by Finder's selection.
    /// Rung 1 otherwise: the folder opened without activation, its window found (by `AXDocument`, else
    /// by a title equal to the folder's name), the item selected through accessibility and read back
    /// selected. Finder's column view refuses the selection write (measured 15 Oct); list view takes it.
    public func reveal(_ path: String) async throws -> MacOpenReport {
        guard reader.isTrusted else { throw MacLaunchFailure.notTrusted }
        let item = try Self.existingItem(path)
        let folder = item.deletingLastPathComponent()
        guard let finder = workspace.application(bundleID: Self.finderBundleID) else {
            throw MacLaunchFailure.notFound("Finder")
        }
        let guardian = await MacFocusGuard.begin(workspace)

        if self.finder.isPermitted() {
            var reason: String?
            do {
                try await self.finder.reveal(item)
                let selected = try await self.finder.selection().map { $0.resolvingSymlinksInPath().path }
                if !selected.contains(item.resolvingSymlinksInPath().path) {
                    reason = "Finder's selection is \(selected), not \(item.lastPathComponent)"
                }
            } catch {
                reason = "Finder's reveal failed: \(error)"
            }
            let processID = workspace.running(bundleID: Self.finderBundleID)?.processID ?? 0
            let window = (try? await reader.windows(of: processID))?.first { Self.shows(folder, $0) }
            let focus = await guardian.settle(after: processID)
            return MacOpenReport(operation: "reveal", route: "api: Finder reveal", app: finder, processID: processID,
                                 window: window, reason: reason, focus: focus)
        }

        workspace.watchFront(of: Self.finderBundleID, restoring: guardian.front?.processID)
        let running = try await workspace.open([folder], with: finder)
        let window = try await launcher.poll { () -> MacWindowSummary? in
            (try? await reader.windows(of: running.processID))?.first { Self.shows(folder, $0) }
        }
        let route = "accessibility: AXSelected (no Automation permission for Finder)"
        guard let window else {
            let focus = await guardian.settle(after: running.processID)
            return MacOpenReport(operation: "reveal", route: route, app: finder, processID: running.processID,
                                 window: nil, reason: "no Finder window shows \(folder.path)", focus: focus)
        }

        var reason: String?
        do {
            try await select(item.lastPathComponent, in: window, of: running.processID)
            let read = try await reader.read(windowAt: window.index, of: running.processID, limits: Self.fullRead)
            if MacTreeLookup.finderItem(named: item.lastPathComponent, in: read.window)?.isSelected != true {
                reason = "\(item.lastPathComponent) is not selected after the write"
            }
        } catch {
            reason = "\(item.lastPathComponent) could not be selected: \(error)"
        }
        let focus = await guardian.settle(after: running.processID)
        return MacOpenReport(operation: "reveal", route: route, app: finder, processID: running.processID,
                             window: window, reason: reason, focus: focus)
    }

    /// Finder's windows carry no `AXDocument`: their title is the folder's name.
    static func shows(_ folder: URL, _ window: MacWindowSummary) -> Bool {
        window.shows(folder) || (window.document == nil && window.title == folder.lastPathComponent)
    }

    private func select(_ name: String, in window: MacWindowSummary, of processID: pid_t) async throws {
        let read = try await reader.read(windowAt: window.index, of: processID, limits: Self.fullRead)
        guard let node = MacTreeLookup.finderItem(named: name, in: read.window) else {
            throw MacOpenFailure.itemNotInWindow(name)
        }
        let address = MacElementAddress(processID: processID, windowIndex: window.index, path: node.path,
                                        role: node.role, visibleOnly: false)
        try await actor.select(address)
    }

    /// Opens a file with an app (by any name `MacLauncher` resolves), or with the system's default app
    /// for it. Read back: a window of that app shows the file, by `AXDocument`, else by its title.
    public func open(_ path: String, with appRequest: String?) async throws -> MacOpenReport {
        guard reader.isTrusted else { throw MacLaunchFailure.notTrusted }
        let item = try Self.existingItem(path)
        let app: MacApp
        if let appRequest {
            app = try launcher.resolve(appRequest)
        } else {
            guard let fallback = workspace.defaultApplication(for: item) else { throw MacOpenFailure.noApplication(path) }
            app = fallback
        }
        guard !MacRefusedApps.refuses(app) else { throw MacLaunchFailure.refused(app.displayName) }

        let guardian = await MacFocusGuard.begin(workspace)
        workspace.watchFront(of: app.bundleID, restoring: guardian.front?.processID)
        let running = try await workspace.open([item], with: app)
        let window = try await launcher.poll { () -> MacWindowSummary? in
            (try? await reader.windows(of: running.processID))?.first { window in
                window.shows(item) || (window.document == nil && Self.title(window.title, names: item))
            }
        }
        let focus = await guardian.settle(after: running.processID)
        return MacOpenReport(operation: "open with \(app.displayName)", route: "workspace: open without activation", app: app, processID: running.processID,
                             window: window, reason: window == nil ? "no window of \(app.displayName) shows \(item.lastPathComponent)" : nil,
                             focus: focus)
    }

    // MARK: Support

    private func focusedWindow(of processID: pid_t) async -> MacWindowSummary? {
        let windows = (try? await reader.windows(of: processID)) ?? []
        return windows.first(where: \.isFocused) ?? windows.first(where: \.isMain) ?? windows.first
    }

    static func existingItem(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw MacOpenFailure.itemNotFound(path) }
        return url
    }

    /// A window title names the file when it is the file's name, with or without its extension.
    static func title(_ title: String?, names item: URL) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return title == item.lastPathComponent || title == item.deletingPathExtension().lastPathComponent
            || title.hasPrefix(item.lastPathComponent + " ")
    }
}

/// MacOpenReport says what a background open did and whether its effect was read back.
public struct MacOpenReport: Sendable, Equatable {

    public var operation: String
    /// How it ran, and why a rung above was skipped.
    public var route: String
    public var app: MacApp
    public var processID: pid_t
    /// The window the effect was read in; its frame says where it appeared.
    public var window: MacWindowSummary?
    /// Nil when the effect was read back; otherwise why it was not (the outcome is `actedUnverified`).
    public var reason: String?
    public var focus: MacFocusGuard.Outcome

    public init(
        operation: String,
        route    : String,
        app      : MacApp,
        processID: pid_t,
        window   : MacWindowSummary?,
        reason   : String?,
        focus    : MacFocusGuard.Outcome
    ) {
        self.operation = operation
        self.route     = route
        self.app       = app
        self.processID = processID
        self.window    = window
        self.reason    = reason
        self.focus     = focus
    }

    public var isVerified: Bool { reason == nil }
}

public enum MacOpenFailure: Error, Equatable, Sendable {
    case itemNotFound(String)
    case itemNotInWindow(String)
    case noApplication(String)
    case paneNotFound(String)
    case didNotOpen(String)
    case scriptFailed(String)
}
