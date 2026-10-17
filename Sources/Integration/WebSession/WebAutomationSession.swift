//
//  WebAutomationSession.swift
//  Braus
//

import AutomationRuntime
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import WebDriver
import WebDriving

/// WebAutomationSession is a session on one Chrome tab: `open` takes an address, starts Braus's
/// own Chrome on first use and loads the page; every later call goes through the engine and the
/// recorder exactly as a desktop session's does.
///
/// Opening another address while a page is open loads it in the same tab, as a person types a new
/// address: no close is needed between pages. Chrome runs on its own profile, never the user's.
@MainActor
public final class WebAutomationSession: AutomationSessionOperating {

    private let knowledgeDirectory: URL
    private let allowsDestructive : Bool
    private let allowsLocalFiles  : Bool
    /// How Chrome starts, read when the session launches it: a change applies from the next launch.
    public var launchOptions: ChromeLaunchOptions
    private var browser  : WebBrowser?
    private var page     : WebPage?
    private var processID: pid_t?
    private var runtime  : WebEngineRuntime?
    private var appKey   : String?
    private var profile  : String?
    public private(set) var id: UUID?

    /// The profiles a session's Chrome runs on now: Chrome lets one process at a time use a
    /// profile, so a second session on the same one is refused before it launches anything.
    private static var profilesInUse: Set<String> = []

    /// The answer to a `file://` address while local files are not allowed.
    public static let localFileRefusal = "Braus does not open local files in its browser: the page would be read "
        + "into the scene and the memory. Open the file with its own app instead."

    /// `allowsLocalFiles` lets `open` load a `file://` address. Off by default, since whatever the file
    /// holds reaches the scene, the model and the memory; a test's local fixture turns it on.
    public init(
        knowledgeDirectory: URL,
        launchOptions     : ChromeLaunchOptions,
        allowsDestructive : Bool = false,
        allowsLocalFiles  : Bool = false
    ) {
        self.knowledgeDirectory = knowledgeDirectory
        self.launchOptions      = launchOptions
        self.allowsDestructive  = allowsDestructive
        self.allowsLocalFiles   = allowsLocalFiles
    }

    /// The address `word` names, or nil when it names no page: `web:` followed by an address or a
    /// host, or an `http`, `https` or `file` URL. A `file` URL is named so that `open` refuses it
    /// with a sentence instead of the desktop looking for an app of that name.
    public nonisolated static func address(in word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = trimmed
        if trimmed.lowercased().hasPrefix("web:") { rest = String(trimmed.dropFirst(4)) }
        let lower = rest.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") { return rest }
        guard rest != trimmed, !rest.isEmpty, !rest.contains(" ") else { return nil }
        return "https://" + rest
    }

    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
        guard let address = Self.address(in: word) else {
            throw AutomationFailure("A web session opens an address: web:<host> or an http(s) URL.")
        }
        guard allowsLocalFiles || !address.lowercased().hasPrefix("file:") else {
            throw AutomationFailure(Self.localFileRefusal)
        }
        if let page {
            try await page.navigate(to: address)
            return try await observe()
        }
        // Without the trailing slash a path takes once the directory exists, so both spellings match.
        var profile = launchOptions.userDataDirectory.standardizedFileURL.path(percentEncoded: false)
        while profile.count > 1, profile.hasSuffix("/") { profile.removeLast() }
        guard !Self.profilesInUse.contains(profile) else {
            throw AutomationFailure("Another session is using Braus's Chrome profile. Try again once it closes.")
        }
        Self.profilesInUse.insert(profile)
        self.profile = profile
        do {
            let browser = try await WebBrowser.launch(launchOptions)
            self.browser = browser
            let page = try await browser.openPage()
            self.page = page
            let runtime = WebEngineRuntime(knowledgeDirectory: knowledgeDirectory)
            self.runtime = runtime
            processID = runtime.tabs.register(page)
            id = UUID()
            try await page.navigate(to: address)
            return try await observe()
        } catch {
            await close()
            throw error
        }
    }

    public func observe() async throws -> SceneSnapshot {
        let (processID, runtime) = try current()
        let perceived = try await runtime.scenes.currentScene(of: processID)
        appKey = perceived.scene.bundleID
        return await recorder(runtime).observe(perceived)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        let (processID, runtime) = try current()
        if verb == .setToggle, desiredState != .on && desiredState != .off {
            throw AutomationFailure("set_toggle requires value on or off.")
        }
        let request = ActionRequest(processID: processID, bundleID: currentKey, appName: appName, target: target,
                                    verb: verb, section: section, desiredState: desiredState)
        return await enriched(
            runtime.engine(recorder: recorder(runtime), allowsDestructive: allowsDestructive).act(request), by: runtime
        )
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        let (processID, runtime) = try current()
        let request = InputRequest(processID: processID, bundleID: currentKey, appName: appName, input: input,
                                   section: section)
        return await enriched(
            runtime.engine(recorder: recorder(runtime), allowsDestructive: allowsDestructive).deliver(request),
            by: runtime
        )
    }

    /// Opens `control`'s list and chooses `item` in it: two engine clicks, each verified, the second only when the
    /// first opened a list. A native select's list is drawn as a window over the page, and its item is chosen in it.
    /// An ARIA list opens in the page itself (W05), so no window is waited for. The control is resolved in the scene
    /// first and clicked by its element, so the list looked for is the one that very control opened, never another
    /// control's open in the page. Its option of that name is clicked by its node, and the control is read back
    /// after the page settled, which decides the check.
    public func select(control: String, item: String) async throws -> ActOutcome {
        let (processID, runtime) = try current()
        return try await Self.select(control: control, item: item, processID: processID, runtime: runtime) { target in
            try await self.act(target: target, verb: .click, section: nil, desiredState: nil)
        }
    }

    /// `select`'s choice in the tab `processID`, every click through `click`, which acts as the session's `act` does.
    static func select(
        control  : String,
        item     : String,
        processID: pid_t,
        runtime  : WebEngineRuntime,
        click    : (String) async throws -> ActOutcome
    ) async throws -> ActOutcome {
        // The control as the engine will resolve it for a click, so its node is the list's owner.
        let resolved = try await runtime.scenes.element(resolving: control, in: processID)
        let opened = try await click(resolved?.element.id ?? control)
        if (try? runtime.windows.windows(ownedBy: processID).count) ?? 0 > 1 {
            return try await click(item)
        }
        guard opened.kind == .foundActed || opened.kind == .actedUnverified, let owner = resolved?.identity else {
            return opened
        }
        switch await runtime.controls.ariaOption(named: item, owner: owner, in: processID) {
            case .noList:
                return opened
            case .missing(let reason):
                return ActOutcome(.honestMiss, "'\(item)' is not in the list '\(control)' opened: \(reason). Only the "
                    + "opening click was sent. Observe the list before choosing again.", scene: opened.scene)
            case .refused(let reason):
                return ActOutcome(.refused, "'\(item)' was not chosen: \(reason). Only the opening click was sent; no "
                    + "option was clicked.", scene: opened.scene)
            case .option(let identity):
                // The option by its own node, in a read of the document it was found in: twins by their ordinal, never
                // by a place another row may hold. The click goes only to that document, though the engine reads again.
                let (perceived, option) = try await runtime.scenes.currentScene(of: processID, naming: identity)
                guard let option else {
                    return ActOutcome(.refused, "'\(item)' was not chosen: the option found is no longer that node in "
                        + "the page's scene (the list changed, the page navigated, or the option is outside the view). "
                        + "Only the opening click was sent; no option was clicked. Observe the list before choosing "
                        + "again.", scene: perceived.scene)
                }
                let chosen = try await runtime.scenes.holding(identity, in: processID) { try await click(option) }
                guard chosen.kind == .foundActed || chosen.kind == .actedUnverified else { return chosen }
                return Self.judged(chosen, item: item, control: control,
                                   readBack: await runtime.controls.ariaReadBack(expecting: item, in: processID))
        }
    }

    /// The outcome of a click on an ARIA list's option, judged by what its control reads back, never by the list's
    /// closing or the scene's difference alone. Nothing is chosen again after the click went out.
    static func judged(_ chosen: ActOutcome, item: String, control: String, readBack: WebControls.AriaReadBack) -> ActOutcome {
        let target = chosen.check?.target
        switch readBack {
            case .confirmed(let value):
                return ActOutcome(.foundActed, "chose '\(item)' in '\(control)': after the page settled the control "
                    + "reads it", scene: chosen.scene, check: OperationCheck(
                        condition: .valueReadBack, method: .controlValue, verdict: .passed, expected: item,
                        observed: value, performed: .requested, target: target))
            case .contradicted(let value):
                return ActOutcome(.actedUnverified, "clicked '\(item)' in '\(control)', but after the page settled the "
                    + "control reads '\(value)': the choice did not hold. Observe and re-decide; do not choose it again "
                    + "blindly.", scene: chosen.scene, check: OperationCheck(
                        condition: .valueReadBack, method: .controlValue, verdict: .failed, expected: item,
                        observed: value, performed: .requested, target: target))
            case .unread(let reason):
                return ActOutcome(.actedUnverified, "clicked '\(item)' in '\(control)', but the control could not be "
                    + "read back (\(reason)): observe it before anything else; do not choose it again blindly.",
                    scene: chosen.scene, check: OperationCheck(
                        condition: .valueReadBack, method: .controlValue, verdict: .unknown, expected: item,
                        limits: [.readbackUnavailable], performed: .requested, target: target))
        }
    }

    public func close() async {
        let runtime = self.runtime
        let browser = self.browser
        if let processID { runtime?.tabs.remove(processID) }
        self.runtime   = nil
        self.browser   = nil
        self.page      = nil
        self.processID = nil
        self.appKey    = nil
        id = nil
        await runtime?.finish()
        await browser?.close()
        // Given back once Chrome has quit, so the next session finds the profile free.
        if let profile { Self.profilesInUse.remove(profile) }
        self.profile = nil
    }

    /// The tab, as the window listing of its synthetic id answers.
    public func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        try runtime?.windows.windows(ownedBy: processID) ?? []
    }

    public var memoryDirectory: URL? { knowledgeDirectory }

    public var memoryApplication: String? { appKey }

    private var currentKey: String { appKey ?? "web:blank" }

    private var appName: String { String(currentKey.dropFirst(4)) }

    private func recorder(_ runtime: WebEngineRuntime) -> CallRecorder {
        CallRecorder.current ?? runtime.recorder(ActionContext(
            source: .system, streamID: "session-\(id?.uuidString ?? "none")", sessionID: id?.uuidString
        ))
    }

    private func enriched(_ outcome: ActOutcome, by runtime: WebEngineRuntime) async -> ActOutcome {
        if let scene = outcome.scene { appKey = scene.bundleID }
        guard let scene = outcome.scene else { return outcome }
        return outcome.with(scene: await recorder(runtime).enrich(scene))
    }

    private func current() throws -> (pid_t, WebEngineRuntime) {
        guard let processID, let runtime else {
            throw AutomationFailure("No live web session. Use open_session with web:<host> or a URL, then observe.")
        }
        return (processID, runtime)
    }
}
