//
//  WebSessionTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
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
            launchOptions     : ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile"))
        )
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

    static func rows(_ sql: String, at url: URL) throws -> [String] {
        let connection = try SQLiteConnection(path: url.path, readOnly: true)
        defer { connection.close() }
        return try connection.query(sql) { try $0.text(0) ?? "" }
    }
}
