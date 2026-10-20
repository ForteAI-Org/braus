//
//  SecureFieldTests.swift
//  Braus
//

import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import JavaScriptCore
import Memory
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving
import WebSession

/// W1: a password field of a web page never shows its value, whatever the field is called. The scripts are
/// the ones `WebControls` sends, run in JavaScriptCore on a synthetic DOM; the stack is Braus's own web
/// roles, engine and recorder over a `SyntheticPage`, with a memory in a temporary directory. What only a
/// real Chrome can show (how its tree reports a password field, a frame's own document) is the L1 tier's.
@Suite("Web secure fields (W1)")
struct SecureFieldTests {

    static let sentinel = "Prefilled-Secret-4417"

    // MARK: The scripts, on a synthetic DOM

    /// The value `script` returns on the DOM `setup` builds, as JSON text; "undefined" when it returns none.
    private func run(_ script: String, after setup: String) throws -> String {
        let context = try #require(JSContext())
        context.evaluateScript(SyntheticPage.dom)
        context.evaluateScript(setup)
        let value = context.evaluateScript("JSON.stringify(\(script))")
        if let exception = context.exception { throw TestFailure("the script threw: \(exception)") }
        return value?.isUndefined == false ? value?.toString() ?? "undefined" : "undefined"
    }

    private let password = "var pw = __input(11, 'password', 'Accesso', '\(sentinel)', [0, 0, 10, 10]);"

    @Test("the focused field's value: none for a password field in the page, a shadow root or a same-origin frame")
    func focusedPasswordIsNotRead() throws {
        let cases = [
            "page"        : password + "document.activeElement = pw;",
            "shadow root" : password + "document.activeElement = { tagName: 'X-LOGIN', shadowRoot: { activeElement: pw } };",
            "same-origin frame": password
                + "document.activeElement = { tagName: 'IFRAME', contentDocument: { activeElement: pw } };",
        ]
        for (place, setup) in cases {
            let answer = try run(WebControls.focusedFieldScript, after: setup)
            #expect(answer == "null", "\(place): \(answer)")
            #expect(!answer.contains(Self.sentinel), "\(place)")
        }
    }

    @Test("the focused field's value: an ordinary text field is still read back")
    func focusedTextIsRead() throws {
        let setup = "var name = __input(12, 'text', 'Nome', 'Ada Lovelace', [0, 0, 10, 10]); document.activeElement = name;"
        #expect(try run(WebControls.focusedFieldScript, after: setup) == "\"Ada Lovelace\"")
    }

    @Test("the controls' values leave out a password field and keep an ordinary one")
    func controlValuesLeaveOutPasswords() throws {
        let answer = try run(WebControls.controlValuesScript,
                             after: password + "__input(12, 'text', 'Nome', 'Ada Lovelace', [0, 0, 10, 10]);")
        #expect(!answer.contains(Self.sentinel), Comment(rawValue: answer))
        #expect(answer.contains("Ada Lovelace"), Comment(rawValue: answer))
    }

    // MARK: The stack, over a synthetic page

    private static let fields = [
        SyntheticPage.Field(backendID: 11, type: "password", name: "Accesso", value: sentinel,
                            box: CGRect(x: 100, y: 100, width: 300, height: 30)),
        SyntheticPage.Field(backendID: 12, type: "text", name: "Nome", value: "Ada",
                            box: CGRect(x: 100, y: 200, width: 300, height: 30)),
    ]

    @Test("scene, outcome, check and memory hold no prefilled password, under a neutral label; the text field works")
    @MainActor
    func stackKeepsThePasswordOut() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("braus-w1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = SyntheticPage(fields: Self.fields)
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        let runtime = WebEngineRuntime(knowledgeDirectory: directory, tabs: tabs)
        // Each call its own recorder, as the tools make one per call.
        func recorder() -> CallRecorder {
            runtime.recorder(ActionContext(source: .app, streamID: "w1", traceID: "w1", sessionID: "s1"))
        }
        let app = AppContextIdentity(bundleID: WebSceneBuilder.appKey(for: "https://fixture.test/login"))

        // The scene the model reads.
        let observing = recorder()
        try await observing.begin(.observe(full: true), app: app)
        let perceived = try await runtime.scenes.currentScene(of: processID)
        let scene = await observing.observe(perceived)
        try await observing.end(.completed, result: nil, tool: .observe)
        let secure = try #require(scene.elements.first { $0.label == "Accesso" })
        #expect(secure.role == "AXSecureTextField")
        #expect(secure.value == nil)
        #expect(scene.elements.first { $0.label == "Nome" }?.value == "Ada", "an ordinary field keeps its value")
        #expect(!scene.mapText().contains(Self.sentinel))

        // Typing after the prefilled value: a read-back would hold it. Never read back, the text kept out of the check.
        let typing = recorder()
        let request = InputRequest(processID: processID, bundleID: app.bundleID, appName: "fixture",
                                   input: .typeText("typed-word", into: "Accesso", replacing: false))
        try await typing.begin(.typeText(target: "Accesso", text: "typed-word", section: nil, replace: false), app: app)
        let typed = await runtime.engine(recorder: typing, allowsDestructive: false).deliver(request)
        try await typing.end(.completed, result: .outcome(typed.kind, message: typed.message), tool: .typeText,
                             check: typed.check)
        #expect(page.value(of: 11) == Self.sentinel + "typed-word", "the text did reach the field, after its value")
        #expect(typed.kind == .actedUnverified, Comment(rawValue: typed.message))
        #expect(!typed.message.contains(Self.sentinel) && !typed.message.contains("typed-word"),
                Comment(rawValue: typed.message))
        let check = try #require(typed.check)
        #expect(check.verdict == .unknown)
        #expect(check.expected == nil && check.observed == nil)
        #expect(check.limits.contains(.readbackUnavailable) && check.limits.contains(.valueWithheld))
        #expect(typed.scene.map { !$0.mapText().contains("typed-word") } ?? true)

        // The ordinary field still types and reads back.
        let ordinary = await runtime.engine(recorder: recorder(), allowsDestructive: false)
            .deliver(InputRequest(processID: processID, bundleID: app.bundleID, appName: "fixture",
                                  input: .typeText("Grace", into: "Nome", replacing: true)))
        #expect(ordinary.kind == .foundActed, Comment(rawValue: ordinary.message))
        #expect(ordinary.check?.observed == "Grace")

        #expect(await runtime.service.flush(within: .seconds(10)))
        await runtime.service.close()
        #expect(try Self.files(in: directory, holding: Self.sentinel).isEmpty, "the archive keeps no prefilled password")
    }

    /// The files under `directory` whose bytes hold `text`, as UTF-8.
    static func files(in directory: URL, holding text: String) throws -> [String] {
        let needle = Data(text.utf8)
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var found: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            if try Data(contentsOf: url).range(of: needle) != nil { found.append(url.lastPathComponent) }
        }
        return found
    }
}

/// A failure of the test's own setup, with its reason.
struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
