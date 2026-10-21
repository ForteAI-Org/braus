import CoreGraphics
import Foundation
import MacDriver
import Synchronization
import Testing

/// FakeWorkspace plays the system for `MacLauncher`: installed apps, a launch that may activate the
/// app by itself, and the person's last input. It records every activation it was asked for.
final class FakeWorkspace: MacWorkspace {

    struct State {
        var running: [String: MacRunningApp] = [:]
        var front: MacRunningApp?
        var launches: [String] = []
        var activations: [pid_t] = []
        var personIdle: TimeInterval = 600
        var opened: [(items: [URL], app: String)] = []
        var links: [URL] = []
        /// An activation is recorded but the front does not move, as with an app that keeps taking it.
        var ignoresActivation = false
        var styles: [MacLaunchStyle] = []
        var reverts: [String: Int] = [:]
    }

    let apps: [MacApp]
    /// The launched app takes the front by itself, as FaceTime and Safari do.
    let selfActivates: Bool
    let state: Mutex<State>

    init(apps: [MacApp], front: MacRunningApp?, running: [MacRunningApp] = [], selfActivates: Bool = false) {
        self.apps = apps
        self.selfActivates = selfActivates
        var initial = State()
        initial.front = front
        for app in running { initial.running[app.bundleID ?? ""] = app }
        state = Mutex(initial)
    }

    func installedApplications() -> [MacApp] { apps }

    func application(bundleID: String) -> MacApp? { apps.first { $0.bundleID == bundleID } }

    func application(at url: URL) -> MacApp? { apps.first { $0.url.standardizedFileURL == url.standardizedFileURL } }

    func running(bundleID: String) -> MacRunningApp? { state.withLock { $0.running[bundleID] } }

    func frontmost() async -> MacRunningApp? { state.withLock { $0.front } }

    func launch(_ app: MacApp) async throws -> MacRunningApp {
        let process = MacRunningApp(processID: 500, bundleID: app.bundleID, name: app.displayName)
        let activates = selfActivates
        state.withLock { state in
            state.launches.append(app.bundleID)
            state.running[app.bundleID] = process
            if activates { state.front = process }
        }
        return process
    }

    /// A self-activating app launched in `revert` comes in front and is sent back at once, counted.
    func launch(_ app: MacApp, style: MacLaunchStyle, restoring front: pid_t?) async throws -> MacRunningApp {
        let process = MacRunningApp(processID: 500, bundleID: app.bundleID, name: app.displayName)
        let activates = selfActivates
        state.withLock { state in
            state.launches.append(app.bundleID)
            state.styles.append(style)
            state.running[app.bundleID] = process
            switch (activates, style) {
                case (true, .plain) : state.front = process
                case (true, .revert): state.reverts[app.bundleID, default: 0] += 1
                case (false, _)     : break
            }
        }
        return process
    }

    func takeReverts(of bundleID: String) -> Int { state.withLock { $0.reverts.removeValue(forKey: bundleID) ?? 0 } }

    func open(_ items: [URL], with app: MacApp) async throws -> MacRunningApp {
        let process = state.withLock { $0.running[app.bundleID] } ?? MacRunningApp(processID: 500, bundleID: app.bundleID)
        state.withLock { state in
            state.opened.append((items, app.bundleID))
            state.running[app.bundleID] = process
        }
        return process
    }

    func openLink(_ link: URL) async throws {
        state.withLock { $0.links.append(link) }
    }

    func defaultApplication(for item: URL) -> MacApp? { apps.first }

    func activate(_ processID: pid_t) async {
        state.withLock { state in
            state.activations.append(processID)
            guard !state.ignoresActivation else { return }
            state.front = state.running.values.first { $0.processID == processID } ?? MacRunningApp(processID: processID)
        }
    }

    func secondsSincePersonInput() -> TimeInterval { state.withLock { $0.personIdle } }

    func personActsNow() { state.withLock { $0.personIdle = 0 } }
}

/// FakeTreeReader answers from fixed trees per process; a window appears only after `windowAfterPolls`
/// reads of the window list, to play an app that is still starting.
final class FakeTreeReader: MacTreeReading, MacAccessibilityActing {

    let isTrusted: Bool
    let windowsByProcess: [pid_t: [(summary: MacWindowSummary, tree: MacTreeNode)]]
    let windowAfterPolls: Int
    let polls = Mutex(0)
    /// Paths `setSelected` selected, per process; reads show them selected and nothing else.
    let selections = Mutex<[pid_t: [Int]]>([:])
    /// Whether `setSelected` refuses, as Finder's column view does.
    let refusesSelection: Bool

    init(
        isTrusted       : Bool = true,
        windows         : [pid_t: [(summary: MacWindowSummary, tree: MacTreeNode)]],
        windowAfterPolls: Int = 0,
        refusesSelection: Bool = false,
        performFailure  : MacTreeFailure? = nil,
        failureAfterActing: MacTreeFailure? = nil
    ) {
        self.refusesSelection   = refusesSelection
        self.performFailure     = performFailure
        self.failureAfterActing = failureAfterActing
        self.isTrusted        = isTrusted
        self.windowsByProcess = windows
        self.windowAfterPolls = windowAfterPolls
    }

    func windows(of processID: pid_t) throws -> [MacWindowSummary] {
        onMainThread.withLock { $0.append(Thread.isMainThread) }
        let count = polls.withLock { value in
            value += 1
            return value
        }
        guard count > windowAfterPolls else { return [] }
        return (windowsByProcess[processID] ?? []).map(\.summary)
    }

    func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) throws -> MacTreeRead {
        onMainThread.withLock { $0.append(Thread.isMainThread) }
        guard let windows = windowsByProcess[processID], windows.indices.contains(index) else {
            throw MacTreeFailure.windowNotFound(index: index)
        }
        var tree = windows[index].tree.addressed()
        if let selected = selections.withLock({ $0[processID] }) { tree = Self.selecting(selected, in: tree) }
        return MacTreeRead(window: tree, nodesVisited: tree.flattened.count)
    }

    // MARK: Acting

    /// Every step sent, in order: `perform AXPress [0, 1]`, `select [0, 0]`, `focus [0]`, `scroll down [0]`.
    let steps = Mutex<[String]>([])
    /// What `perform` throws, for every action; nil sends it.
    let performFailure: MacTreeFailure?
    /// What `perform` throws after the action took effect, as an app that acts and still answers an error.
    let failureAfterActing: MacTreeFailure?
    /// Whether each read and acting call ran on the main thread, in order.
    let onMainThread = Mutex<[Bool]>([])

    func perform(_ action: String, on element: MacElementAddress) throws {
        onMainThread.withLock { $0.append(Thread.isMainThread) }
        try check(element)
        if let performFailure { throw performFailure }
        steps.withLock { $0.append("perform \(action) \(element.path)") }
        if let failureAfterActing { throw failureAfterActing }
    }

    func select(_ element: MacElementAddress) throws {
        onMainThread.withLock { $0.append(Thread.isMainThread) }
        if refusesSelection { throw MacTreeFailure.actionFailed("AXSelectedChildren: AXError -25205") }
        try check(element)
        selections.withLock { $0[element.processID] = element.path }
        steps.withLock { $0.append("select \(element.path)") }
    }

    func focus(_ element: MacElementAddress) throws {
        onMainThread.withLock { $0.append(Thread.isMainThread) }
        try check(element)
        steps.withLock { $0.append("focus \(element.path)") }
    }

    func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) throws -> String {
        onMainThread.withLock { $0.append(Thread.isMainThread) }
        try check(area)
        steps.withLock { $0.append("scroll \(direction.rawValue) \(area.path)") }
        return "scroll bar AXValue"
    }

    func readBack(_ element: MacElementAddress) -> MacTreeNode? { node(at: element) }

    private func node(at element: MacElementAddress) -> MacTreeNode? {
        guard let windows = windowsByProcess[element.processID], windows.indices.contains(element.windowIndex) else { return nil }
        var node = windows[element.windowIndex].tree.addressed()
        for step in element.path {
            guard node.children.indices.contains(step) else { return nil }
            node = node.children[step]
        }
        return node
    }

    /// The live tree is the fixed one: a path to another role or name is stale.
    private func check(_ element: MacElementAddress) throws {
        guard let node = node(at: element), node.role == element.role else { throw MacTreeFailure.staleTarget(path: element.path) }
        if let name = element.name {
            let names = [node.title, node.descriptionText, node.help, node.placeholder, node.value].compactMap { $0 }
                + node.flattened.filter { $0.role == "AXStaticText" }.compactMap(\.value)
            guard names.contains(name) else { throw MacTreeFailure.staleTarget(path: element.path) }
        }
    }

    private static func selecting(_ path: [Int], in node: MacTreeNode) -> MacTreeNode {
        var node = node
        if node.isSelected != nil || node.path == path { node.isSelected = node.path == path }
        node.children = node.children.map { selecting(path, in: $0) }
        return node
    }
}

enum Trees {

    /// A recorded window tree from `Trees/`, written by `braus mac record`.
    static func recorded(_ name: String) throws -> MacTreeNode {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Trees"))
        return try JSONDecoder().decode(MacTreeNode.self, from: Data(contentsOf: url)).addressed()
    }

    static func read(_ name: String) throws -> MacTreeRead {
        let tree = try recorded(name)
        return MacTreeRead(window: tree, nodesVisited: tree.flattened.count)
    }

    static func window(_ title: String, _ frame: CGRect, children: [MacTreeNode]) -> MacTreeNode {
        MacTreeNode(role: "AXWindow", subrole: "AXStandardWindow", title: title, frame: frame, children: children)
            .addressed()
    }
}

/// FakeFinderScripting plays Finder's scripting: permitted or not, and a selection that follows
/// `reveal` unless `ignoresReveal`.
final class FakeFinderScripting: MacFinderScripting {

    let permitted: Bool
    let ignoresReveal: Bool
    let revealed = Mutex<[URL]>([])

    init(permitted: Bool, ignoresReveal: Bool = false) {
        self.permitted     = permitted
        self.ignoresReveal = ignoresReveal
    }

    func isPermitted() -> Bool { permitted }

    func reveal(_ item: URL) async throws { revealed.withLock { $0.append(item) } }

    func selection() async throws -> [URL] { ignoresReveal ? [] : revealed.withLock { $0 } }
}
