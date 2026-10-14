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
    private let launchOptions     : ChromeLaunchOptions
    private var browser  : WebBrowser?
    private var page     : WebPage?
    private var processID: pid_t?
    private var runtime  : WebEngineRuntime?
    private var appKey   : String?
    public private(set) var id: UUID?

    public init(knowledgeDirectory: URL, launchOptions: ChromeLaunchOptions, allowsDestructive: Bool = false) {
        self.knowledgeDirectory = knowledgeDirectory
        self.launchOptions      = launchOptions
        self.allowsDestructive  = allowsDestructive
    }

    /// The address `word` names, or nil when it names no page: `web:` followed by an address or a
    /// host, or an `http`, `https` or `file` URL.
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
        if let page {
            try await page.navigate(to: address)
            return try await observe()
        }
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

    /// Opens `control`'s list and chooses `item` in it: two engine clicks, each verified, the second
    /// only when the first opened a list.
    public func select(control: String, item: String) async throws -> ActOutcome {
        let opened = try await act(target: control, verb: .click, section: nil, desiredState: nil)
        guard let processID, let runtime, (try? runtime.windows.windows(ownedBy: processID).count) ?? 0 > 1 else {
            return opened
        }
        return try await act(target: item, verb: .click, section: nil, desiredState: nil)
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
