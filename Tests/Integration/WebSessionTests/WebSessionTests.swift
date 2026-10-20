//
//  WebSessionTests.swift
//  Braus
//

import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Router
@testable import SQLiteMemory
import Testing
import WebDriver
import WebSession

/// A desktop session that records what reaches it and opens nothing.
@MainActor
final class DesktopProbe: AutomationSessionOperating {
    var calls: [String] = []
    private(set) var id: UUID?

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open \(application)")
        id = UUID()
        return SceneSnapshot(bundleID: "com.example.App", appName: "App", windowTitle: "Main",
                             viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [])
    }
    func observe() async throws -> SceneSnapshot { calls.append("observe"); throw AutomationFailure("probe") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        calls.append("act \(target)"); throw AutomationFailure("probe")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("probe") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw AutomationFailure("probe") }
    func close() async { calls.append("close"); id = nil }
    func resolvedBundleID(of application: String) async -> String? {
        calls.append("resolve \(application)"); return "com.example.App"
    }
    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] { calls.append("windows \(processID)"); return [] }
}

@MainActor
@Suite("Web session")
struct WebSessionTests {

    @Test("An address is web: with a host or a URL; an application name is not")
    func addresses() {
        #expect(WebAutomationSession.address(in: "web:whatsapp.com") == "https://whatsapp.com")
        #expect(WebAutomationSession.address(in: "web:https://app.slack.com/client") == "https://app.slack.com/client")
        #expect(WebAutomationSession.address(in: "https://notion.so") == "https://notion.so")
        #expect(WebAutomationSession.address(in: "file:///tmp/a.html") == "file:///tmp/a.html")
        #expect(WebAutomationSession.address(in: "Safari") == nil)
        #expect(WebAutomationSession.address(in: "Google Chrome") == nil)
    }

    @Test("An application name goes to the desktop session, and later calls follow it")
    func routesToDesktop() async throws {
        let desktop = DesktopProbe()
        let web     = DesktopProbe()
        let router  = RoutingAutomationSession(desktop: desktop, web: web)
        _ = try await router.open(application: "Finder", window: nil)
        _ = try? await router.act(target: "Back", verb: .click, section: nil, desiredState: nil)
        #expect(desktop.calls == ["open Finder", "act Back"])
        #expect(web.calls.isEmpty)
        #expect(router.id == desktop.id)
    }

    @Test("An address goes to the web session and closes an open desktop one")
    func routesToWeb() async throws {
        let desktop = DesktopProbe()
        let web     = DesktopProbe()
        let router  = RoutingAutomationSession(desktop: desktop, web: web)
        _ = try await router.open(application: "Finder", window: nil)
        _ = try await router.open(application: "web:example.com", window: nil)
        #expect(desktop.calls == ["open Finder", "close"])
        #expect(web.calls == ["open web:example.com"])
        #expect(router.id == web.id)
    }

    @Test("A file address goes to the web session, which refuses it before starting Chrome")
    func refusesLocalFiles() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "braus-web-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let desktop = DesktopProbe()
        let web     = WebAutomationSession(
            knowledgeDirectory: temporary.appending(path: "Knowledge"),
            launchOptions     : ChromeLaunchOptions(
                executableURL    : temporary.appending(path: "no-chrome"),
                userDataDirectory: temporary.appending(path: "profile")
            )
        )
        let router  = RoutingAutomationSession(desktop: desktop, web: web)
        for address in ["file:///tmp/a.html", "web:file:///tmp/a.html", "FILE:///tmp/a.html"] {
            let refusal = await #expect(throws: AutomationFailure.self) {
                _ = try await router.open(application: address, window: nil)
            }
            #expect(refusal?.description == WebAutomationSession.localFileRefusal)
        }
        #expect(desktop.calls.isEmpty)
        #expect(web.id == nil)
        #expect(!FileManager.default.fileExists(atPath: temporary.appending(path: "profile").path))
    }

    @Test("An address names no application; any other name resolves as the desktop resolves it")
    func resolvesOnlyApplications() async {
        let desktop = DesktopProbe()
        let router  = RoutingAutomationSession(desktop: desktop, web: DesktopProbe())
        #expect(await router.resolvedBundleID(of: "web:notes.example.com") == nil)
        #expect(await router.resolvedBundleID(of: "https://example.com") == nil)
        #expect(await router.resolvedBundleID(of: "Notes") == "com.example.App")
        #expect(desktop.calls == ["resolve Notes"])
    }

    @Test("A negative window id is a tab the web session lists; any other id is the desktop's")
    func listsWindowsBySide() async throws {
        let desktop = DesktopProbe()
        let web     = DesktopProbe()
        let router  = RoutingAutomationSession(desktop: desktop, web: web)
        _ = try await router.windowCandidates(ownedBy: -100)
        _ = try await router.windowCandidates(ownedBy: 42)
        #expect(web.calls == ["windows -100"])
        #expect(desktop.calls == ["windows 42"])
    }

    @Test("Closing the router closes both sides")
    func closesBoth() async throws {
        let desktop = DesktopProbe()
        let web     = DesktopProbe()
        let router  = RoutingAutomationSession(desktop: desktop, web: web)
        _ = try await router.open(application: "web:example.com", window: nil)
        await router.close()
        #expect(desktop.calls == ["close"])
        #expect(web.calls == ["open web:example.com", "close"])
        #expect(router.id == nil)
    }
}

/// The web session behind the tools on a real headless Chrome and the local fixture, with a real
/// memory in a temporary directory. Opt in with `BRAUS_WEB_LIVE_TESTS=1`.
@MainActor
@Suite(
    "Web session, live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct WebSessionLiveTests {

    static func json(_ text: String) -> LocalMCP.JSONValue {
        (try? JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    @Test("Open, type, press and choose through the tools; the memory keeps the page as web:file")
    func throughTheTools() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "braus-web-session-\(UUID().uuidString)")
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let web = WebAutomationSession(
            knowledgeDirectory: knowledge,
            launchOptions     : ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile")),
            allowsLocalFiles  : true
        )
        // The session is closed on a throw too, so its Chrome never outlives the test (W14).
        do {
            let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web))
            tools.producer = CallProducer(source: .app, streamID: "web-1", traceID: "message-1", messageRef: "message-1")
            let fixture = try #require(Bundle.module.url(forResource: "web-session", withExtension: "html"))

            let opened = try await tools.call("open_session", Self.json(#"{"app":"\#(fixture.absoluteString)"}"#))
            let id = try #require(web.id?.uuidString, "\(opened)")
            _ = try await tools.call("memory_task", Self.json(#"{"operation":"begin","goal":"Send a note to Ada"}"#))
            let typed = try await tools.call("type_text", Self.json(#"{"session":"\#(id)","target":"Name","text":"Ada"}"#))
            #expect(typed["isError"].bool != true, "\(typed)")
            let sent = try await tools.call("act", Self.json(#"{"session":"\#(id)","target":"Send"}"#))
            #expect(sent["isError"].bool != true, "\(sent)")
            let chose = try await tools.call("select", Self.json(#"{"session":"\#(id)","control":"Color","item":"Blue"}"#))
            #expect(chose["isError"].bool != true, "\(chose)")
            _ = try await tools.call("memory_task", Self.json(#"{"operation":"end","outcome":"completed"}"#))
            let seen = try await web.observe()
            #expect(seen.elements.contains { $0.label == "Color Blue" })
        } catch {
            await web.close()
            throw error
        }
        await web.close()

        let archive = knowledge.appendingPathComponent("memory.sqlite")
        #expect(try Self.rows("SELECT bundle_id FROM brain_apps", at: archive) == ["web:file"])
        // The three calls are the agent's actions on the page, and the task left a candidate procedure of three
        // steps for the page, the D2 block a desktop application's task leaves.
        #expect(try Self.rows("""
            SELECT DISTINCT b.bundle_id FROM memory_agent_actions a JOIN brain_apps b ON b.app_id = a.app_id
            """, at: archive) == ["web:file"])
        #expect(try Self.rows("SELECT count(*) FROM memory_agent_actions", at: archive) == ["3"])
        #expect(try Self.rows("""
            SELECT DISTINCT b.bundle_id FROM memory_candidate_steps s JOIN brain_apps b ON b.app_id = s.app_id
            """, at: archive) == ["web:file"])
        #expect(try Self.rows("SELECT count(*) FROM memory_candidate_steps", at: archive) == ["3"])
    }

    @Test("What a secure field holds reaches neither the tools' answers nor any file of the memory")
    func secureFieldsStayOutOfTheMemory() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "braus-web-secure-\(UUID().uuidString)")
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let web = WebAutomationSession(
            knowledgeDirectory: knowledge,
            launchOptions     : ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile")),
            allowsLocalFiles  : true
        )
        let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web))
        tools.producer = CallProducer(source: .app, streamID: "web-secure", traceID: "message-1", messageRef: "message-1")
        let fixture = try #require(Bundle.module.url(forResource: "web-secure", withExtension: "html"))
        let secrets = ["4111111111111111", "secret-cvc-737", "secret-otp-654321", "hunter2-secret"]

        let opened   = try await tools.call("open_session", Self.json(#"{"app":"\#(fixture.absoluteString)"}"#))
        let id       = try #require(web.id?.uuidString, "\(opened)")
        let observed = try await tools.call("observe", Self.json(#"{"session":"\#(id)","full":true}"#))
        let answers  = "\(opened)\(observed)"
        #expect(answers.contains("Quantity") && answers.contains("10115"), "\(answers)")
        #expect(!secrets.contains { answers.contains($0) }, "\(answers)")
        await web.close()

        let files = FileManager.default.enumerator(at: knowledge, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        #expect(files.contains { $0.lastPathComponent == "memory.sqlite" })
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for secret in secrets { #expect(data.range(of: Data(secret.utf8)) == nil, "\(secret) in \(file.lastPathComponent)") }
        }
    }

    @Test("A second session on the same profile is refused until the first closes")
    func oneSessionPerProfile() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "braus-web-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let options = ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile"))
        let first   = WebAutomationSession(knowledgeDirectory: temporary.appending(path: "A"), launchOptions: options, allowsLocalFiles: true)
        let second  = WebAutomationSession(knowledgeDirectory: temporary.appending(path: "B"), launchOptions: options, allowsLocalFiles: true)
        let fixture = try #require(Bundle.module.url(forResource: "web-session", withExtension: "html"))

        // Both sessions are closed on a throw too; closing one never opened does nothing (W14).
        do {
            _ = try await first.open(application: fixture.absoluteString, window: nil)
            await #expect(throws: AutomationFailure.self) {
                _ = try await second.open(application: fixture.absoluteString, window: nil)
            }
            #expect(second.id == nil)
            await first.close()
            _ = try await second.open(application: fixture.absoluteString, window: nil)
            #expect(second.id != nil)
        } catch {
            await first.close()
            await second.close()
            throw error
        }
        await second.close()
    }

    static func rows(_ sql: String, at url: URL) throws -> [String] {
        let connection = try SQLiteConnection(path: url.path, readOnly: true)
        defer { connection.close() }
        return try connection.query(sql) { try $0.text(0) ?? "" }
    }
}

/// Braus's Chrome as a window the person can watch: driven from inside, it must never take the
/// person's focus. Opt in with `BRAUS_WEB_WINDOW_TESTS=1`, since a window appears on screen.
@Suite(
    "Web session, visible window",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_WINDOW_TESTS"] == "1")
)
@MainActor
struct WebSessionWindowTests {

    @Test("A visible Chrome is driven through the tools and the frontmost app never changes")
    func visibleWindowKeepsFocus() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "braus-web-window-\(UUID().uuidString)")
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let web = WebAutomationSession(
            knowledgeDirectory: knowledge,
            launchOptions     : ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile"), isHeadless: false),
            allowsLocalFiles  : true
        )
        let tools   = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web))
        let fixture = try #require(Bundle.module.url(forResource: "web-session", withExtension: "html"))
        let front   = WebSessionWindowTests.frontName()

        let opened = try await tools.call("open_session", WebSessionLiveTests.json(#"{"app":"\#(fixture.absoluteString)"}"#))
        let id = try #require(web.id?.uuidString, "\(opened)")
        try await Task.sleep(for: .seconds(1))
        let afterOpen = WebSessionWindowTests.frontName()
        #expect(afterOpen == front, "opening took the focus: \(front) -> \(afterOpen)")
        let typed = try await tools.call("type_text", WebSessionLiveTests.json(#"{"session":"\#(id)","target":"Name","text":"Ada"}"#))
        #expect(typed["isError"].bool != true, "\(typed)")
        let sent = try await tools.call("act", WebSessionLiveTests.json(#"{"session":"\#(id)","target":"Send"}"#))
        #expect(sent["isError"].bool != true, "\(sent)")
        try await Task.sleep(for: .seconds(2))
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        #expect(windows.contains { ($0[kCGWindowOwnerName as String] as? String) == "Google Chrome"
            && ($0[kCGWindowLayer as String] as? Int) == 0
            && ($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0 > 600 },
            "no Chrome window is on screen")
        let afterAct = WebSessionWindowTests.frontName()
        #expect(afterAct == front, "acting took the focus: \(front) -> \(afterAct)")
        await web.close()
    }

    /// The frontmost application as Launch Services reports it now, read outside this process.
    static func frontName() -> String {
        let process = Process()
        let pipe    = Pipe()
        process.executableURL  = URL(fileURLWithPath: "/bin/sh")
        process.arguments      = ["-c", "lsappinfo info -only name $(lsappinfo front)"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
