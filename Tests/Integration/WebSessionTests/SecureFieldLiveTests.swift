//
//  SecureFieldLiveTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import Engine
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Router
import Testing
import WebDriver
@testable import WebDriving
import WebSession

/// W1 on a real headless Chrome with a new temporary profile, removed afterwards, and the local fixture
/// `secure-fields.html`: what only Chrome can show. How its accessibility tree reports a password field,
/// one with an explicit ARIA role, a shadow root's input, a same-origin frame; and the session behind the
/// tools, whose every call goes through the production `CallRecorder` into a memory in a temporary
/// directory, scanned for the prefilled values afterwards. W1's typed secrets on the real protocol: an ordinary
/// field classified by its node and typed and inserted bound, with exact values; a password field typed withheld,
/// proved by an exact comparison the page answers as a boolean and by its counted input events, never by its
/// value. Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`; no network, no account.
@MainActor
@Suite(
    "Web secure fields, live (W1)",
    .serialized,
    .timeLimit(.minutes(2)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct SecureFieldLiveTests {

    /// Every prefilled value of the fixture begins with it: page, shadow root, frame and ARIA fields.
    static let sentinel = "Prefilled-Secret-4417"
    /// The password fields of the main frame's tree, by label, the frame's own being in its own tree.
    static let secureLabels = ["Accesso", "Codice", "Riservato", "Parola"]

    static func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "secure-fields", withExtension: "html"))
    }

    static func withPage(_ body: (WebTabs, pid_t, WebPage) async throws -> Void) async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-w1-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile, isHeadless: true))
        do {
            let page = try await browser.openPage()
            try await page.navigate(to: try Self.fixture().absoluteString)
            let tabs = WebTabs()
            try await body(tabs, tabs.register(page), page)
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }

    @Test("the scene shows every password field of the main tree as secure with no value, ARIA roles included")
    func scene() async throws {
        try await Self.withPage { tabs, id, page in
            let window = try await WebScenes(tabs: tabs).currentScene(of: id)
            for label in Self.secureLabels {
                let field = try #require(window.scene.elements.first { $0.label == label }, "\(label)")
                #expect(field.role == "AXSecureTextField" && field.value == nil, "\(label): \(String(describing: field))")
            }
            #expect(window.scene.elements.first { $0.label == "Nome" }?.value == "Ada")
            #expect(!window.scene.mapText().contains(Self.sentinel))
            // Recorded, not asserted: the role and value Chrome's own tree gives each password field.
            let tree = try await page.send("Accessibility.getFullAXTree")
            for node in tree["nodes"]?.arrayValue ?? [] {
                guard let name = node["name"]?["value"]?.stringValue, Self.secureLabels.contains(name) else { continue }
                let role  = node["role"]?["value"]?.stringValue ?? "none"
                let plain = node["value"]?["value"]?.stringValue?.contains(Self.sentinel) == true
                print("W1 L1: Chrome's tree: '\(name)' role \(role), prefilled value in plain text: \(plain)")
            }
        }
    }

    @Test("a focused password field, in the page, a shadow root or the frame, reads as no value; Nome reads Ada")
    func focusedReadBack() async throws {
        try await Self.withPage { tabs, id, page in
            let controls = WebControls(tabs: tabs)
            let focus = [
                "page"  : "document.getElementById('access').focus()",
                "aria"  : "document.getElementById('combo').focus()",
                "shadow": "document.querySelector('x-login').shadowRoot.getElementById('pin').focus()",
                "frame" : "document.getElementById('frame').contentDocument.getElementById('inner').focus()",
            ]
            for (place, script) in focus {
                _ = try await page.evaluate(script)
                #expect(await controls.focusedFieldValue(in: id) == nil, "\(place)")
            }
            _ = try await page.evaluate("document.getElementById('name').focus()")
            #expect(await controls.focusedFieldValue(in: id) == "Ada")
            let values = try await page.evaluate(WebControls.controlValuesScript)
            #expect(!String(describing: values).contains(Self.sentinel), "\(values)")
        }
    }

    // MARK: W1 typed secrets on the real DevTools protocol

    /// The engine over a tab's web roles, as the web session composes it, without a recorder.
    static func engine(_ tabs: WebTabs) -> ActionEngine {
        ActionEngine(ActionEngine.Dependencies(
            scenes: WebScenes(tabs: tabs), actuator: WebActuator(tabs: tabs), windows: WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs), settling: WebSettler(tabs: tabs)
        ))
    }

    /// Whether the field `id` holds exactly `text`: the page answers a boolean, never the value.
    static func holds(_ id: String, _ text: String, on page: WebPage) async throws -> Bool {
        try await page.evaluate("window.__holds('\(id)', \(WebControls.jsString(text)))").boolValue == true
    }

    /// How many input events reached the field `id`.
    static func inputs(_ id: String, on page: WebPage) async throws -> Int {
        try await page.evaluate("window.__inputs['\(id)'] || 0").intValue ?? 0
    }

    @Test("an ordinary field on Chrome: classified ordinary by its node, typed bound, then inserted bound at the focus it left; the values are exact")
    func boundOrdinaryTyping() async throws {
        try await Self.withPage { tabs, id, page in
            let engine = Self.engine(tabs)
            var typing = InputRequest(processID: id, bundleID: "web:file", appName: "fixture",
                                      input: .typeText("Grace", into: "Nome", replacing: true))
            let classified = await engine.classify(typing)
            typing.binding = try #require(classified.binding, "Chrome attests the field: \(classified)")
            let typed = await engine.deliver(typing)
            #expect(typed.kind == .foundActed, Comment(rawValue: typed.message))
            #expect(typed.check?.verdict == .passed && typed.check?.observed == "Grace")
            #expect(try await Self.holds("name", "Grace", on: page))
            var inserting = InputRequest(processID: id, bundleID: "web:file", appName: "fixture",
                                         input: .insertText(" Hopper", expecting: "Grace Hopper"))
            let focus = await engine.classify(inserting)
            inserting.binding = try #require(focus.binding, "Chrome attests the focus: \(focus)")
            #expect(inserting.binding?.identity == typing.binding?.identity, "the focus is the node typed into")
            let inserted = await engine.deliver(inserting)
            #expect(inserted.kind == .foundActed, Comment(rawValue: inserted.message))
            #expect(inserted.check?.verdict == .passed && inserted.check?.observed == "Grace Hopper")
            #expect(try await Self.holds("name", "Grace Hopper", on: page))
            #expect(try await Self.inputs("name", on: page) >= 2, "each text reached the field")
        }
    }

    /// Typed secrets whose JSON form differs from their own; a password input keeps no line break.
    nonisolated static let typedSecrets = ["Typed-Q7z9", "Ty\"ped-Q7z9", "Ty\\ped-Q7z9"]

    @Test("a password field on Chrome: classified secure, typed withheld; the field holds exactly the text (a boolean) and its events counted, nothing of it answered",
          arguments: typedSecrets)
    func passwordEffectWithoutTheSecret(text: String) async throws {
        try await Self.withPage { tabs, id, page in
            let engine = Self.engine(tabs)
            var typing = InputRequest(processID: id, bundleID: "web:file", appName: "fixture",
                                      input: .typeText(text, into: "Accesso", replacing: true))
            #expect(await engine.classify(typing) == .secure)
            typing.withholdsText = true
            let typed = await engine.deliver(typing)
            #expect(typed.kind == .actedUnverified, Comment(rawValue: typed.message))
            #expect(!typed.message.contains(text) && !typed.message.contains("Q7z9") && !typed.message.contains(Self.sentinel))
            #expect(typed.check?.expected == nil && typed.check?.observed == nil && typed.check?.limits.contains(.valueWithheld) == true)
            #expect(typed.scene.map { !$0.mapText().contains("Q7z9") } ?? true)
            let holds = try await Self.holds("access", text, on: page)
            let events = try await Self.inputs("access", on: page)
            #expect(holds, "the field holds exactly the typed text")
            #expect(events >= 1, "the text reached the field")
        }
    }

    @Test("through the tools on Chrome: an ordinary text kept and visible; password texts typed, their effect counted on the page, none of them in the answers, the transcript or the archive")
    func typedThroughTheTools() async throws {
        try await Self.withSession { web, knowledge in
            let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web))
            tools.producer = CallProducer(source: .app, streamID: "web-w1-typed", traceID: "message-1", messageRef: "message-1")
            let transcript = Transcript()
            tools.record = { transcript.lines.append($0) }
            _ = try await tools.call("open_session", .object(["app": .string(try Self.fixture().absoluteString)]))
            let id = try #require(web.id?.uuidString)
            func call(_ name: String, _ arguments: [String: LocalMCP.JSONValue]) async throws -> LocalMCP.JSONValue {
                var arguments = arguments
                arguments["session"] = .string(id)
                return try await tools.call(name, .object(arguments))
            }
            let ordinary = try await call("type_text", ["target": .string("Nome"), "text": .string("Grace"),
                                                        "replace": .bool(true)])
            #expect(TypedSecretTests.status(of: ordinary) == "found_acted", "\(ordinary)")
            var answers: [LocalMCP.JSONValue] = []
            for text in Self.typedSecrets {
                answers.append(try await call("type_text", ["target": .string("Accesso"), "text": .string(text),
                                                            "replace": .bool(true)]))
            }
            let observed = try await call("observe", ["full": .bool(true)])
            answers.append(observed)
            let seen = TypedSecretTests.strings(in: observed)
            #expect(seen.contains { $0.contains("Nome") && $0.contains("Grace") }, "the ordinary value is shown")
            #expect(seen.contains { $0.contains("Modifiche Accesso:") && !$0.contains("Modifiche Accesso: 0") },
                    "the password field took the texts")
            await web.close()
            #expect(try !SecureFieldTests.files(in: knowledge, holding: "Grace").isEmpty, "the ordinary text is kept")
            for text in Self.typedSecrets {
                for needle in try TypedSecretTests.forms(of: text) + ["Q7z9", Self.sentinel] {
                    for answer in answers {
                        #expect(!TypedSecretTests.strings(in: answer).contains { $0.contains(needle) }, "answer holds \(needle)")
                    }
                    #expect(!transcript.lines.contains { TypedSecretTests.values(of: $0).contains { $0.contains(needle) } },
                            "transcript holds \(needle)")
                    #expect(try SecureFieldTests.files(in: knowledge, holding: needle).isEmpty, "archive holds \(needle)")
                }
            }
        }
    }

    /// The lines the tools hand to the transcript.
    final class Transcript { var lines: [String] = [] }

    /// Runs `body` on a web session over a new temporary profile and memory, and closes the session on
    /// success and on error alike before the directory is removed: Chrome has quit (`close` waits for
    /// it) when its profile goes. A failed open closes what it started itself; closing again is a no-op.
    static func withSession(_ body: (WebAutomationSession, URL) async throws -> Void) async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "braus-web-w1-\(UUID().uuidString)")
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        let web = WebAutomationSession(
            knowledgeDirectory: knowledge,
            launchOptions     : ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile"), isHeadless: true),
            allowsLocalFiles  : true
        )
        do {
            try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
            try await body(web, knowledge)
        } catch {
            await web.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        await web.close()
        try? FileManager.default.removeItem(at: temporary)
    }

    @Test("through the tools and the recorder: no prefilled or typed password in the answers, the transcript or the archive")
    func throughTheRecorder() async throws {
        try await Self.withSession { web, knowledge in try await Self.record(through: web, into: knowledge) }
    }

    /// Opens the fixture, observes it and types into its password field through the tools, then closes the
    /// session, which flushes the memory, and scans what the calls left.
    static func record(through web: WebAutomationSession, into knowledge: URL) async throws {
        let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web))
        tools.producer = CallProducer(source: .app, streamID: "web-w1", traceID: "message-1", messageRef: "message-1")
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        func answer(_ name: String, _ arguments: String) async throws -> String {
            let value = try await tools.call(name, Self.json(arguments))
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }

        var answers: [String] = []
        answers.append(try await answer("open_session", #"{"app":"\#(try Self.fixture().absoluteString)"}"#))
        let id = try #require(web.id?.uuidString, "\(answers)")
        answers.append(try await answer("observe", #"{"session":"\#(id)","full":true}"#))
        let typed = try await answer("type_text",
                                     #"{"session":"\#(id)","target":"Accesso","text":"typed-word","replace":false}"#)
        answers.append(typed)
        #expect(!typed.contains("\"isError\":true"), Comment(rawValue: typed))
        #expect(!typed.contains("typed-word"), "the answer keeps no typed text: \(typed)")
        // Closed here so the memory is flushed before the scan; `withSession` closes again on any path.
        await web.close()

        for text in answers { #expect(!text.contains(Self.sentinel), Comment(rawValue: text)) }
        #expect(!transcript.lines.contains { $0.contains(Self.sentinel) }, "the transcript keeps no prefilled value")
        #expect(try SecureFieldTests.files(in: knowledge, holding: Self.sentinel).isEmpty,
                "the archive keeps no prefilled value")
        // W1 typed secrets: the call classified the field secure before its first write, so its text is withheld
        // from the call's arguments, the transcript and every file of the archive.
        let typedKept = try SecureFieldTests.files(in: knowledge, holding: "typed-word")
        #expect(typedKept.isEmpty, "archive files holding the typed text: \(typedKept)")
        #expect(!transcript.lines.contains { $0.contains("typed-word") })
    }

    static func json(_ text: String) -> LocalMCP.JSONValue {
        (try? JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(text.utf8))) ?? .null
    }
}
