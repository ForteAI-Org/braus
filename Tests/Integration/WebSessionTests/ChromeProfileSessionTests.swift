//
//  ChromeProfileSessionTests.swift
//  Braus
//

import AutomationRuntime
import Foundation
import Synchronization
import Testing
@testable import WebDriver
import WebSession

/// A web session on a paired Chrome profile (`chromeProfile`): off by default; a profile that cannot be used is
/// refused with nothing opened and no fallback; a change of the conversation's choice refuses the next call with
/// nothing sent, and the session closes only its own tab. A scripted browser stands in for the profile's extension;
/// no Chrome runs.
@MainActor
@Suite("A web session on a paired Chrome profile")
struct ChromeProfileSessionTests {

    /// ScriptedProfile answers what a session's first open sends through a profile's transport, with a navigation
    /// that loads at once on an empty page, and records every method it receives.
    final class ScriptedProfile: CDPTransporting {
        let incoming: AsyncStream<Data>
        private let feed : AsyncStream<Data>.Continuation
        private let state = Mutex<(methods: [String], isClosed: Bool)>(([], false))

        init() { (incoming, feed) = AsyncStream<Data>.makeStream() }

        var methods: [String] { state.withLock { $0.methods } }

        func send(_ message: Data) throws {
            let command = try JSONDecoder().decode(JSONValue.self, from: message)
            let method  = command["method"]?.stringValue ?? ""
            let isClosed = state.withLock { state in
                if !state.isClosed { state.methods.append(method) }
                return state.isClosed
            }
            if isClosed { throw CDPError.connectionClosed(method: method) }
            let result: JSONValue
            switch method {
                case "Browser.getVersion"   : result = ["product": "Chrome profile 'Lavoro' (scripted)"]
                case "Target.createTarget"  : result = ["targetId": "tab-7"]
                case "Target.attachToTarget": result = ["sessionId": "tab-7"]
                case "Page.navigate"        : result = ["frameId": "main"]
                case "Page.getLayoutMetrics": result = ["cssLayoutViewport": ["clientWidth": 1280, "clientHeight": 720]]
                case "DOM.getDocument"      : result = ["root": ["backendNodeId": 1, "nodeName": "#document"]]
                case "Accessibility.getFullAXTree":
                    result = ["nodes": [["nodeId": "root", "ignored": false, "role": ["value": "RootWebArea"],
                                         "name": ["value": "Home"], "childIds": [], "backendDOMNodeId": 1]]]
                case "DOMSnapshot.captureSnapshot":
                    result = ["documents": [["documentURL": 1, "title": 2, "scrollOffsetX": 0, "scrollOffsetY": 0,
                                             "nodes": ["nodeName": [0], "attributes": [[]], "backendNodeId": [1]],
                                             "layout": ["nodeIndex": [0], "bounds": [[0, 0, 1280, 720]]]]],
                              "strings": ["#document", "https://example.invalid/home", "Home"]]
                default                     : result = [:]
            }
            var framed = try JSONEncoder().encode(JSONValue.object(["id": command["id"] ?? .null, "result": result]))
            framed.append(0)
            feed.yield(framed)
        }

        func close() {
            state.withLock { $0.isClosed = true }
            feed.finish()
        }
    }

    /// Counts the calls of a connect closure.
    final class Calls: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    static let lavoro = ChromeProfileChoice(instanceID: "B-instance", label: "Lavoro")

    /// A session whose Braus's Chrome cannot start (its executable does not exist), whose person's Chrome is
    /// `personalChrome` (refused unless given), and whose paired profile is `connect`.
    static func session(
        connect       : @escaping @Sendable (String, CommandGate) async throws -> WebBrowser,
        personal      : Calls = Calls(),
        personalChrome: (@Sendable () async throws -> WebBrowser)? = nil
    ) throws -> WebAutomationSession {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "braus-profile-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        return WebAutomationSession(
            knowledgeDirectory: knowledge,
            launchOptions: ChromeLaunchOptions(executableURL: temporary.appending(path: "no-chrome"),
                                               userDataDirectory: temporary.appending(path: "chrome-web")),
            connectPersonalChrome: {
                personal.add()
                guard let personalChrome else { throw PersonalChromeError.refused }
                return try await personalChrome()
            },
            connectProfile: connect
        )
    }

    @Test("off by default: no profile is reached")
    func offByDefault() async throws {
        let calls = Calls()
        let session = try Self.session { _, _ in calls.add(); throw ChromeProfileTestError.unused }
        #expect(session.chromeProfile == nil)
        await #expect(throws: (any Error).self) { try await session.open(application: "web:x.com", window: nil) }
        #expect(calls.value == 0)
    }

    @Test("a chosen profile that cannot be used is refused: nothing opened, no other profile, browser or desktop")
    func unavailableProfile() async throws {
        let personal = Calls()
        let asked = Mutex<[String]>([])
        let session = try Self.session(connect: { id, _ in
            asked.withLock { $0.append(id) }
            throw ChromeProfileTestError.disconnected
        }, personal: personal)
        session.chromeProfile = Self.lavoro
        session.usesPersonalChrome = true
        do {
            _ = try await session.open(application: "web:x.com", window: nil)
            Issue.record("opened")
        } catch let failure as AutomationFailure {
            let text = failure.description
            for part in ["Braus could not use the Chrome profile 'Lavoro'", "paired but not connected",
                         "No page was opened", "Do not move to another profile, browser or the desktop"] {
                #expect(text.contains(part), "\(part): \(text)")
            }
            #expect(!text.contains("no-chrome"), "Braus's own Chrome was not launched")
        }
        #expect(asked.withLock { $0 } == ["B-instance"], "the chosen instance only")
        #expect(personal.value == 0, "the profile takes precedence over Use My Chrome: no fallback to it")
        #expect(session.id == nil && session.browserNotice == nil)
    }

    @Test("the choice turned off while the profile was connecting: no tab opened or page navigated there")
    func choiceChangedWhileConnecting() async throws {
        let profile = ScriptedProfile()
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let session = try Self.session { _, _ in
            enter.yield()
            for await _ in released { break }
            return try await WebBrowser.attached(over: profile, readySeconds: 5)
        }
        session.chromeProfile = Self.lavoro
        let opening = Task { try await session.open(application: "https://example.invalid/home", window: nil) }
        for await _ in entered { break }
        session.chromeProfile = nil
        release.yield()
        do {
            _ = try await opening.value
            Issue.record("the page opened in the profile chosen before")
        } catch let failure as AutomationFailure {
            #expect(failure.description.contains("changed while Braus was opening the page in 'Lavoro'"))
            #expect(failure.description.contains("nothing more was sent there"))
        }
        let methods = profile.methods
        #expect(!methods.contains("Target.createTarget") && !methods.contains("Page.navigate"),
                "no new tab or navigation in the profile chosen before: \(methods)")
        #expect(!methods.contains("Browser.close"), "never the browser: \(methods)")
        #expect(session.id == nil)
    }

    @Test("a profile chosen while the page is open elsewhere: the next call is refused with nothing sent")
    func profileChosenMidTurn() async throws {
        let profile = ScriptedProfile()
        let session = try Self.session(
            connect       : { _, _ in throw ChromeProfileTestError.unused },
            personalChrome: { try await WebBrowser.attached(over: profile, readySeconds: 5) }
        )
        session.usesPersonalChrome = true
        _ = try await session.open(application: "https://example.invalid/home", window: nil)
        let opened = profile.methods.count
        session.chromeProfile = Self.lavoro
        do {
            _ = try await session.observe()
            Issue.record("observed in the person's Chrome after a profile was chosen")
        } catch let failure as AutomationFailure {
            #expect(failure.description.contains("changed since the page was opened in the person's own Chrome"))
            #expect(failure.description.contains("nothing was sent"))
        }
        #expect(profile.methods.count == opened, "nothing sent: \(profile.methods[opened...])")
    }

    @Test("a page in a profile no longer chosen: refused in the turn, then closed between turns, Braus's tab only")
    func supersededBetweenTurns() async throws {
        let profile = ScriptedProfile()
        let session = try Self.session { _, _ in try await WebBrowser.attached(over: profile, readySeconds: 5) }
        session.chromeProfile = Self.lavoro
        _ = try await session.open(application: "https://example.invalid/home", window: nil)
        await session.closeIfSuperseded()
        #expect(session.id != nil, "the choice is unchanged: the page stays open")
        session.chromeProfile = nil
        let opened = profile.methods.count
        do {
            _ = try await session.observe()
            Issue.record("observed in 'Lavoro' after the choice was turned off")
        } catch let failure as AutomationFailure {
            #expect(failure.description.contains("profile changed since the page was opened in 'Lavoro'"))
            #expect(failure.description.contains("nothing was sent"))
        }
        #expect(profile.methods.count == opened, "nothing sent during the turn")
        await session.closeIfSuperseded()
        #expect(session.id == nil)
        #expect(profile.methods.contains("Target.closeTarget") && !profile.methods.contains("Browser.close"),
                "only Braus's tab is closed: \(profile.methods)")
    }

    @Test("what the agent reads names the profile by the person's name, and never as Braus's own")
    func texts() {
        let notice = WebAutomationSession.profileNotice("Lavoro")
        #expect(notice.contains("Chrome profile 'Lavoro', paired with Braus"))
        #expect(notice.contains("ask the person before"))
        let failure = WebAutomationSession.navigationFailure(
            address: "https://x.com/home?token=Sentinel-P", error: CDPError.protocolError(
                method: "Page.navigate", code: 0, message: "net::ERR_NAME_NOT_RESOLVED"),
            showsWindow: false, profileLabel: "Lavoro", closed: true)?.description ?? ""
        for part in ["the person's Chrome profile 'Lavoro', in a tab Braus opened", "signs in themselves",
                     "Braus closed the tab it opened", "another profile or browser"] {
            #expect(failure.contains(part), "\(part): \(failure)")
        }
        #expect(!failure.contains("Braus's own profile") && !failure.contains("Sentinel"), "\(failure)")
    }
}

/// The errors a test's connect closure throws in place of the hub's.
enum ChromeProfileTestError: Error, CustomStringConvertible {
    case unused, disconnected
    var description: String {
        switch self {
            case .unused      : "unused"
            case .disconnected: "the Chrome profile 'Lavoro' is paired but not connected"
        }
    }
}
