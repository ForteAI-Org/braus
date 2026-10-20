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
/// address: no close is needed between pages. Chrome runs on its own profile, never the user's, unless
/// the person chose their own Chrome for the conversation (`usesPersonalChrome`): then the session opens
/// its tab in a window of the person's running Chrome, signed in as them, and closes only that tab.
@MainActor
public final class WebAutomationSession: AutomationSessionOperating {

    private let knowledgeDirectory: URL
    private let allowsDestructive : Bool
    private let allowsLocalFiles: Bool
    /// How Chrome starts, read when the session launches it: a change applies from the next launch.
    public var launchOptions: ChromeLaunchOptions
    /// Whether the session's next Chrome is the person's own, reached with their consent, instead of Braus's:
    /// read when the session opens its first page, so a change applies from the next open after a close.
    public var usesPersonalChrome = false
    /// Reaches the person's own Chrome (`PersonalChrome.connect`); a test gives its own.
    private let connectPersonalChrome: @Sendable () async throws -> WebBrowser
    /// Whether the open page is in the person's own Chrome.
    private var isOnPersonalChrome = false
    /// The paired Chrome profile the conversation chose (`ChromeProfileHub`); nil, the default, uses none. It takes
    /// precedence over `usesPersonalChrome`. Read when the session opens its first page. A change closes the gate of
    /// the profile chosen before at once, so a call under way sends nothing more there; it stops an open under way,
    /// and refuses the session's next calls, with nothing sent, until the session is closed and opened again.
    public var chromeProfile: ChromeProfileChoice? {
        didSet {
            guard chromeProfile?.instanceID != oldValue?.instanceID else { return }
            choiceGeneration += 1
            gate?.close()
        }
    }
    /// Counts the changes of `chromeProfile`, so an open checks after each wait that the choice it began with holds.
    private var choiceGeneration = 0
    /// The gate every new command to the paired profile reached passes; closed when the choice changes.
    private var gate: CommandGate?
    /// Reaches a paired profile by its instance ID through a gate (`ChromeProfileHub.connect`); the app gives it, a
    /// test its own.
    private let connectProfile: @Sendable (String, CommandGate) async throws -> WebBrowser
    /// The paired profile the open page is in; nil in Braus's own Chrome or the person's (`usesPersonalChrome`).
    private var boundProfile: ChromeProfileChoice?
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

    public init(
        knowledgeDirectory   : URL,
        launchOptions        : ChromeLaunchOptions,
        allowsDestructive    : Bool = false,
        allowsLocalFiles     : Bool = false,
        connectPersonalChrome: @escaping @Sendable () async throws -> WebBrowser = {
            try await PersonalChrome.connect()
        },
        connectProfile: @escaping @Sendable (String, CommandGate) async throws -> WebBrowser = { _, _ in
            throw AutomationFailure("Braus is not listening for its Chrome extension.")
        }
    ) {
        self.knowledgeDirectory    = knowledgeDirectory
        self.launchOptions         = launchOptions
        self.allowsDestructive     = allowsDestructive
        self.allowsLocalFiles      = allowsLocalFiles
        self.connectPersonalChrome = connectPersonalChrome
        self.connectProfile        = connectProfile
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

    /// The route this session is when no routing session fronts it (M05).
    public var dispatchRoute: CallRoute.Route? { .web }

    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
        guard let address = Self.address(in: word) else {
            throw AutomationFailure("A web session opens an address: web:<host> or an http(s) URL.")
        }
        guard allowsLocalFiles || !address.lowercased().hasPrefix("file:") else {
            throw AutomationFailure(Self.localFileRefusal)
        }
        if let page {
            try await checkProfile()
            // The tab may now show Chrome's error page or another document: the failure says to observe.
            do { try await page.navigate(to: address) } catch {
                throw Self.navigationFailure(address: address, error: error, showsWindow: !launchOptions.isHeadless,
                                             personal: isOnPersonalChrome, profileLabel: boundProfile?.label,
                                             closed: false) ?? error
            }
            return try await observe()
        }
        let choice     = chromeProfile
        let generation = choiceGeneration
        let personal   = choice == nil && usesPersonalChrome
        let place      = choice.map { "'\($0.label)'" }
            ?? (personal ? "the person's own Chrome" : "Braus's own Chrome")
        // The person's Chrome is theirs, shared by every tab they and Braus open: only Braus's profile is reserved.
        if choice == nil && !personal {
            // Without the trailing slash a path takes once the directory exists, so both spellings match.
            var profile = launchOptions.userDataDirectory.standardizedFileURL.path(percentEncoded: false)
            while profile.count > 1, profile.hasSuffix("/") { profile.removeLast() }
            guard !Self.profilesInUse.contains(profile) else {
                throw AutomationFailure("Another session is using Braus's Chrome profile. Try again once it closes.")
            }
            Self.profilesInUse.insert(profile)
            self.profile = profile
        }
        let options = launchOptions
        do {
            let browser: WebBrowser
            if let choice {
                // The chosen profile or nothing: never another profile, Braus's own Chrome or the desktop.
                let gate = CommandGate()
                self.gate = gate
                do { browser = try await connectProfile(choice.instanceID, gate) } catch {
                    throw Self.profileFailure(label: choice.label, error)
                }
            } else if personal {
                browser = try await connectPersonalChrome()
            } else {
                browser = try await WebBrowser.launch(options)
            }
            self.browser = browser
            isOnPersonalChrome = personal
            boundProfile = choice
            // After each wait, before anything new: the choice the open began with must still hold.
            try checkChoice(since: generation, opening: place)
            let page = try await browser.openPage()
            self.page = page
            try checkChoice(since: generation, opening: place)
            let runtime = WebEngineRuntime(knowledgeDirectory: knowledgeDirectory)
            self.runtime = runtime
            processID = runtime.tabs.register(page)
            id = UUID()
            do { try await page.navigate(to: address) } catch {
                throw Self.navigationFailure(address: address, error: error, showsWindow: !options.isHeadless,
                                             personal: personal, profileLabel: choice?.label, closed: true) ?? error
            }
            return try await observe()
        } catch let unreached as PersonalChromeError {
            await close()
            throw Self.personalChromeFailure(unreached)
        } catch {
            // Chrome is closed: the profile is free, and a window the person chose since applies to the next launch.
            // The person's Chrome stays open with every tab of theirs; only the tab this session opened is closed.
            await close()
            throw error
        }
    }

    /// The failure an agent reads when the person's own Chrome, chosen for the conversation, could not be reached:
    /// what is wrong and what the person does about it. Nothing was opened, and the agent is sent nowhere else.
    public nonisolated static func personalChromeFailure(_ error: PersonalChromeError) -> AutomationFailure {
        let cause: String
        switch error {
            case .remoteDebuggingOff:
                cause = "Chrome is not open, or its remote debugging is off. Ask the person to open Chrome, go to "
                    + "chrome://inspect/#remote-debugging and turn remote debugging on, then open the page again."
            case .unreachable:
                cause = "nothing answers where Chrome said it listens: it quit or turned remote debugging off. Ask the "
                    + "person to open Chrome and check chrome://inspect/#remote-debugging, then open the page again."
            case .refused:
                cause = "Chrome refused the connection: the person did not allow it. Chrome asks them to allow each "
                    + "connection; ask whether they want to, then open the page again."
            case .notAllowedInTime(let seconds):
                cause = "Chrome did not answer within \(Int(seconds)) s: it waits for the person to allow the "
                    + "connection. Ask them to click Allow when Chrome asks, then open the page again."
        }
        return AutomationFailure("Braus could not use the person's own Chrome, which they chose for this conversation "
            + "(Use My Chrome): " + cause + " No page was opened. The person can turn off Use My Chrome (Inspector, "
            + "Web) to use Braus's own Chrome instead. Do not move to another browser or the desktop without asking "
            + "them.")
    }

    /// What an agent reads with every answer while a page is open in the person's own Chrome: whose browser and
    /// sign-ins it acts in, and what it asks the person first.
    public nonisolated static let personalChromeNotice = "This page is in the person's own Chrome, in a window Braus "
        + "opened, signed in as them: act only in this tab, and ask the person before anything that posts, sends, "
        + "buys, deletes or changes their accounts."

    /// `personalChromeNotice` while a page is open in the person's own Chrome, `profileNotice` in a paired profile;
    /// nil in Braus's own.
    public var browserNotice: String? {
        guard page != nil else { return nil }
        if let bound = boundProfile { return Self.profileNotice(bound.label) }
        return isOnPersonalChrome ? Self.personalChromeNotice : nil
    }

    /// What an agent reads with every answer while a page is open in a paired Chrome profile: which profile, by the
    /// name the person gave it, and what it asks the person first.
    public nonisolated static func profileNotice(_ label: String) -> String {
        "This page is in the person's Chrome profile '\(label)', paired with Braus, in a tab Braus opened, signed in "
            + "as that profile: act only in this tab, and ask the person before anything that posts, sends, buys, "
            + "deletes or changes their accounts."
    }

    /// The failure an agent reads when the paired profile chosen for the conversation cannot be used: unknown or
    /// revoked, disconnected, or Braus not listening. Nothing was opened, and the agent is sent nowhere else.
    public nonisolated static func profileFailure(label: String, _ error: any Error) -> AutomationFailure {
        AutomationFailure("Braus could not use the Chrome profile '\(label)' chosen for this conversation: \(error). "
            + "No page was opened. The person can start that Chrome, pair it again in its Braus extension, or choose "
            + "another profile or none (Inspector, Web). Do not move to another profile, browser or the desktop "
            + "without asking them.")
    }

    /// Stops an open under way once the conversation's choice of paired profile changed since it began: nothing more
    /// is sent where it began, and the open's caller closes what it had acquired.
    private func checkChoice(since generation: Int, opening place: String) throws {
        guard choiceGeneration == generation else {
            throw AutomationFailure("This conversation's Chrome profile changed while Braus was opening the page in "
                + "\(place): nothing more was sent there, and Braus closed what it had opened for it. Open the page "
                + "again to open it in the profile now chosen.")
        }
    }

    /// Whether the conversation's choice of paired profile is no longer the one the open page was opened under:
    /// another profile, one chosen since, or none.
    private var choiceChanged: Bool {
        page != nil && chromeProfile?.instanceID != boundProfile?.instanceID
    }

    /// Refuses a call on the open page, with nothing sent, when the conversation's choice of paired profile changed
    /// since the page opened, or when the page is in a paired profile whose extension instance is gone (disconnected,
    /// revoked). What earlier calls sent stands as they reported it, uncertain where they said so.
    private func checkProfile() async throws {
        guard !choiceChanged else {
            let place = boundProfile.map { "'\($0.label)'" }
                ?? (isOnPersonalChrome ? "the person's own Chrome" : "Braus's own Chrome")
            throw AutomationFailure("This conversation's Chrome profile changed since the page was opened in "
                + "\(place): nothing was sent. What earlier calls did there stands as they reported it. The page "
                + "opens in the profile now chosen once this session closes, at the latest when the turn ends.")
        }
        guard let bound = boundProfile, page != nil else { return }
        guard await browser?.isRunning() == true else {
            throw AutomationFailure("The Chrome profile '\(bound.label)' is no longer connected: its Chrome closed, "
                + "its Braus extension stopped, or the person revoked the pairing. Nothing was sent; what earlier "
                + "calls sent may or may not have taken effect. Tell the person; do not move to another profile, "
                + "browser or the desktop without asking them.")
        }
    }

    /// The failure an agent reads when `address` did not load, or nil when `error` is not a navigation's: the
    /// address's origin only (never its path, query, fragment or credentials), Chrome's error and what it means, the
    /// browser that ran (Braus's own Chrome on its own profile, with or without its window, or the person's own Chrome
    /// when `personal`), the way out, and what is left: `closed` when the session closed Chrome (in the person's
    /// Chrome, its own tab), else a tab whose page must be observed (Chrome may show its error page or another
    /// document). It sends the agent nowhere else: moving to another browser or the desktop is the person's choice,
    /// never a silent fallback.
    public nonisolated static func navigationFailure(address: String, error: any Error, showsWindow: Bool,
                                                     personal: Bool = false, profileLabel: String? = nil,
                                                     closed: Bool) -> AutomationFailure? {
        let answered: String
        switch error as? CDPError {
            case .protocolError(method: "Page.navigate", _, let message)?: answered = message
            case .timedOut(method: "Page.navigate", let seconds)?: answered = "no load within \(Int(seconds)) s"
            default: return nil
        }
        let meaning = navigationMeaning(answered).map { " (\($0))" } ?? ""
        let browser = profileLabel.map {
                "the person's Chrome profile '\($0)', in a tab Braus opened, signed in as that profile"
            }
            ?? (personal
            ? "the person's own Chrome, in a window Braus opened, signed in as them"
            : showsWindow
            ? "Braus's own Chrome, in its window on Braus's own profile"
            : "Braus's own Chrome, with no window (headless), on Braus's own profile")
        let isPersons = personal || profileLabel != nil
        let wayOut = isPersons || showsWindow
            ? "If the site asks to sign in, the person signs in themselves in that window."
            : "Some sites refuse a browser with no window, or need the person to sign in: ask the person to turn on "
                + "Show Chrome Window for this conversation (Inspector, Web), then open the page again. It opens in "
                + "a window of Braus's Chrome, where the person signs in themselves if the site asks."
        let left = !closed
            ? "The tab may show Chrome's error page or another document: observe before deciding."
            : isPersons
            ? "Braus closed the tab it opened in the person's Chrome: no page is open in this session."
            : "Braus closed its Chrome: no page is open in this session."
        let elsewhere = profileLabel != nil ? "another profile or browser"
            : personal ? "another browser" : "their own browser"
        return AutomationFailure("The page did not load as asked: \(origin(of: address)) answered "
            + "\(answered)\(meaning) in \(browser). " + wayOut + " " + left + " Tell the person; do not move to "
            + "\(elsewhere) or the desktop without asking them.")
    }

    /// The origin of `address`, scheme, host and port, with nothing else of it; a local file is named as one.
    nonisolated static func origin(of address: String) -> String {
        guard let components = URLComponents(string: address), let scheme = components.scheme?.lowercased() else {
            return "the address"
        }
        if scheme == "file" { return "a local file" }
        guard let host = components.host, !host.isEmpty else { return "the address" }
        return scheme + "://" + host + (components.port.map { ":\($0)" } ?? "")
    }

    /// What Chrome's network error means, in words, for the errors a page commonly fails with; nil for another.
    nonisolated static func navigationMeaning(_ errorText: String) -> String? {
        let code = errorText.hasPrefix("net::") ? String(errorText.dropFirst(5)) : errorText
        switch code {
            case "ERR_HTTP_RESPONSE_CODE_FAILURE": return "the site answered with an HTTP error and an empty page"
            case "ERR_NAME_NOT_RESOLVED": return "the site's name could not be resolved"
            case "ERR_INTERNET_DISCONNECTED": return "this Mac is offline"
            case "ERR_CONNECTION_REFUSED": return "the site refused the connection"
            case "ERR_CONNECTION_RESET", "ERR_CONNECTION_CLOSED": return "the connection was cut"
            case "ERR_CONNECTION_TIMED_OUT", "ERR_TIMED_OUT": return "the site did not answer in time"
            case "ERR_TOO_MANY_REDIRECTS": return "the site redirected too many times"
            case "ERR_BLOCKED_BY_CLIENT", "ERR_BLOCKED_BY_RESPONSE", "ERR_BLOCKED_BY_ADMINISTRATOR":
                return "the page was blocked"
            case "ERR_ABORTED": return "the load was stopped before it finished"
            default:
                return code.hasPrefix("ERR_CERT_") ? "the site's certificate was not accepted" : nil
        }
    }

    /// Closes the session when its page can no longer be used where the conversation now wants it: opened under a
    /// choice of paired profile since changed, or in a paired profile no longer connected. The app calls it between
    /// turns, so the next turn opens its page as the person now chose; during a turn such calls are refused instead.
    public func closeIfSuperseded() async {
        guard page != nil else { return }
        let isConnected = boundProfile == nil ? true : await browser?.isRunning() == true
        if choiceChanged || !isConnected { await close() }
    }

    /// Reads the posts of the page this session holds, scrolling it for more (`WebPostCollector`). Every scroll is
    /// this session's own, under the call's recorder; before each, and after each wait, the session must still be
    /// the one the collection began in, with its profile's choice and connection. Stopping keeps what was read.
    public func collectPosts(_ request: PostCollectionRequest) async throws -> PostCollection {
        try await checkProfile()
        guard let page, let begun = id else {
            throw AutomationFailure("No live web session. Use open_session with web:<host> or a URL, then observe.")
        }
        let (processID, runtime) = try current()
        let collector = WebPostCollector(
            read   : { timeout in try await runtime.tabs.evaluate(WebPostCollector.script, in: processID, timeoutSeconds: timeout) },
            scroll : { [unowned self] pixels in
                let lines = min(InputRequest.maximumScrollLines, max(1, Int((pixels / 40).rounded())))
                let done = try await deliver(.scroll(lines: -lines, over: nil), section: nil)
                if done.kind == .refused || done.kind == .honestMiss {
                    throw AutomationFailure("the scroll was not done: \(done.message)")
                }
            },
            proceed: { [unowned self] in
                try Task.checkCancellation()
                guard id == begun, self.page == page else {
                    throw AutomationFailure("the web session changed or closed")
                }
                try await checkProfile()
            },
            sleep  : { try await Task.sleep(for: $0) },
            now    : { ContinuousClock.now }
        )
        return try await collector.collect(request)
    }

    public func observe() async throws -> SceneSnapshot {
        try await checkProfile()
        let (processID, runtime) = try current()
        let perceived = try await runtime.scenes.currentScene(of: processID)
        appKey = perceived.scene.bundleID
        return await recorder(runtime).observe(perceived)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        try await checkProfile()
        let (processID, runtime) = try current()
        if verb == .setToggle, desiredState != .on && desiredState != .off {
            throw AutomationFailure("set_toggle requires value on or off.")
        }
        let request = ActionRequest(processID: processID, bundleID: currentKey, appName: appName, target: target,
                                    verb: verb, section: section, desiredState: desiredState)
        let recorder = recorder(runtime)
        let outcome  = await runtime.engine(recorder: recorder, allowsDestructive: allowsDestructive).act(request)
        await Self.handRung(of: runtime.tabs, in: processID, to: recorder)
        return await enriched(outcome, by: runtime)
    }

    /// The last send the actuator started in the tab, handed once to the recorder the engine was given (M05): taken
    /// right after the engine, on every outcome, before the scene is enriched, so no later call reads it. A gesture
    /// refused before any command left nothing to take; `select`'s two clicks run under one recorder, so its row is
    /// the last send that went out in the call. The controls' script paths send nothing through the actuator.
    package static func handRung(of tabs: WebTabs, in processID: pid_t, to recorder: CallRecorder) async {
        guard let send = tabs.takeLastSend(for: processID) else { return }
        await recorder.dispatched(rung: CallRung(send))
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await deliver(input, section: section, binding: nil, withholdsText: false)
    }

    public func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        switch dispatch {
            case .bound(let binding): try await deliver(input, section: section, binding: binding, withholdsText: false)
            case .withheld          : try await deliver(input, section: section, binding: nil, withholdsText: true)
        }
    }

    /// Where `input`'s text would go, from a fresh scene of the tab (W1): the engine's classification, with the
    /// node identity the web roles attest. Nothing is sent or recorded.
    public func classify(_ input: InputRequest.Input, section: String?) async -> TextTargetClass {
        guard (try? await checkProfile()) != nil, let (processID, runtime) = try? current() else {
            return .unclassified(.noScene)
        }
        let request = InputRequest(processID: processID, bundleID: currentKey, appName: appName, input: input,
                                   section: section)
        return await runtime.engine(recorder: recorder(runtime), allowsDestructive: allowsDestructive).classify(request)
    }

    private func deliver(_ input: InputRequest.Input, section: String?, binding: TextTargetBinding?,
                         withholdsText: Bool) async throws -> ActOutcome {
        try await checkProfile()
        let (processID, runtime) = try current()
        let request = InputRequest(processID: processID, bundleID: currentKey, appName: appName, input: input,
                                   section: section, binding: binding, withholdsText: withholdsText)
        let recorder = recorder(runtime)
        let outcome  = await runtime.engine(recorder: recorder, allowsDestructive: allowsDestructive).deliver(request)
        await Self.handRung(of: runtime.tabs, in: processID, to: recorder)
        return await enriched(outcome, by: runtime)
    }

    /// Opens `control`'s list and chooses `item` in it: two engine clicks, each verified, the second only when the
    /// first opened a list. A native select's list is drawn as a window over the page, and its item is chosen in it.
    /// An ARIA list opens in the page itself (W05), so no window is waited for. The control is resolved in the scene
    /// first and clicked by its element, so the list looked for is the one that very control opened, never another
    /// control's open in the page. Its option of that name is clicked by its node, and the control is read back
    /// after the page settled, which decides the check.
    public func select(control: String, item: String) async throws -> ActOutcome {
        try await checkProfile()
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
        isOnPersonalChrome = false
        boundProfile = nil
        gate = nil
        id = nil
        await runtime?.finish()
        // Braus's Chrome quits; in the person's Chrome only the tab this session opened closes.
        await browser?.close()
        // Given back once Chrome has quit, so the next session finds the profile free.
        if let profile { Self.profilesInUse.remove(profile) }
        self.profile = nil
    }

    /// The tab, as the window listing of its synthetic id answers.
    public func windowCandidates(ownedBy processID: pid_t) async throws -> [WindowRow] {
        try runtime?.windows.windows(ownedBy: processID) ?? []
    }

    public var memoryDirectory: URL? { knowledgeDirectory }

    public var memoryApplication: String? { appKey }

    /// Which Chrome the open page is in (P2-05): a paired profile by its instance's random ID, the person's own Chrome, or
    /// Braus's; never the account a site has signed in, which nothing here reads.
    public var dataProfile: String? {
        guard page != nil else { return nil }
        if let bound = boundProfile { return "chrome-profile:\(bound.instanceID)" }
        return isOnPersonalChrome ? "personal-chrome" : "braus-chrome"
    }

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

extension CallRung {
    /// The web's send as the record keeps it: the Input method, the counts and the outcome as `how`, nothing skipped.
    package init(_ send: WebSend) {
        self.init(rung: .webInputEvent, how: send.description)
    }
}
