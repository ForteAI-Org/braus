//
//  TextTargetWebTests.swift
//  Braus
//

import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W1 typed secrets on the web roles over a `SyntheticPage`: the physical identity a scene attests for each
/// field (tab, document, DOM node), which a node replaced in the same place does not keep though its scene id
/// does; the focus as the page attests it, never its value; and the engine's classification and bound dispatch
/// through the real web roles. What Chrome itself answers belongs to the Chrome tier.
@Suite("Web text targets (W1 typed secrets)")
struct TextTargetWebTests {

    static let fields = [
        SyntheticPage.Field(backendID: 11, type: "password", name: "Accesso", value: "Prefilled-Secret-4417",
                            box: CGRect(x: 100, y: 100, width: 300, height: 30)),
        SyntheticPage.Field(backendID: 12, type: "text", name: "Nome", value: "Ada",
                            box: CGRect(x: 100, y: 200, width: 300, height: 30)),
    ]

    struct Stack {
        let page     : SyntheticPage
        let tabs     : WebTabs
        let processID: pid_t
        let engine   : ActionEngine
    }

    static func stack() async -> Stack {
        let page = SyntheticPage(fields: fields)
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes: WebScenes(tabs: tabs), actuator: WebActuator(tabs: tabs), windows: WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs), settling: WebSettler(tabs: tabs)
        ))
        return Stack(page: page, tabs: tabs, processID: processID, engine: engine)
    }

    static func identity(of label: String, in window: PerceivedWindow) -> TargetIdentity? {
        window.scene.elements.first { $0.label == label }.flatMap { window.identities[$0.id] }
    }

    static func typing(_ text: String, into field: String, in stack: Stack, binding: TextTargetBinding? = nil) -> InputRequest {
        InputRequest(processID: stack.processID, bundleID: "web:fixture.test", appName: "fixture.test",
                     input: .typeText(text, into: field, replacing: true), binding: binding)
    }

    // MARK: Identity

    @Test("each field's identity names the tab, the document and the node; two reads agree; no value in it")
    func identities() async throws {
        let stack = await Self.stack()
        let scenes = WebScenes(tabs: stack.tabs)
        let first = try await scenes.currentScene(of: stack.processID)
        let accesso = try #require(Self.identity(of: "Accesso", in: first))
        let nome = try #require(Self.identity(of: "Nome", in: first))
        #expect(accesso != nome)
        #expect(nome.token.contains("target-1") && nome.token.hasSuffix("|12"), "\(nome.token)")
        #expect(!accesso.token.contains("Prefilled-Secret-4417") && !nome.token.contains("Ada"))
        let second = try await scenes.currentScene(of: stack.processID)
        #expect(Self.identity(of: "Nome", in: second) == nome)
    }

    @Test("a node replaced in the same place keeps its scene id but not its identity; a new document changes every identity")
    func replacementAndNavigation() async throws {
        let stack = await Self.stack()
        let scenes = WebScenes(tabs: stack.tabs)
        let before = try await scenes.currentScene(of: stack.processID)
        stack.page.change([.replace(12, by: 52)])
        let after = try await scenes.currentScene(of: stack.processID)
        let old = try #require(before.scene.elements.first { $0.label == "Nome" })
        let new = try #require(after.scene.elements.first { $0.label == "Nome" })
        #expect(old.id == new.id && old.role == new.role && old.bounds == new.bounds, "the scene alone cannot tell them apart")
        #expect(Self.identity(of: "Nome", in: before) != Self.identity(of: "Nome", in: after))
        stack.page.change([.navigate])
        let navigated = try await scenes.currentScene(of: stack.processID)
        #expect(Self.identity(of: "Accesso", in: navigated) != Self.identity(of: "Accesso", in: after))
    }

    // MARK: Focus

    @Test("the focus: a text field is ordinary with its scene identity, a password field secure, none unknown")
    func focus() async throws {
        let stack = await Self.stack()
        let controls = WebControls(tabs: stack.tabs)
        let window = try await WebScenes(tabs: stack.tabs).currentScene(of: stack.processID)
        #expect(await controls.focusedField(in: stack.processID) == .unknown, "nothing has the focus")
        stack.page.run("document.activeElement = __fields[1];")
        #expect(await controls.focusedField(in: stack.processID) == .ordinary(try #require(Self.identity(of: "Nome", in: window))))
        stack.page.run("document.activeElement = __fields[0];")
        #expect(await controls.focusedField(in: stack.processID) == .secure(Self.identity(of: "Accesso", in: window)))
        stack.page.run("document.activeElement = { tagName: 'X-LOGIN', shadowRoot: { activeElement: __fields[0] } };")
        if case .secure = await controls.focusedField(in: stack.processID) {} else { Issue.record("shadow root: not secure") }
        stack.page.run("document.activeElement = { tagName: 'IFRAME', contentDocument: null };")
        #expect(await controls.focusedField(in: stack.processID) == .unknown, "a frame it cannot read")
    }

    @Test("the focus is ordinary only on a field text goes into, by the DOM: a text input, a textarea, an editable element",
          arguments: [("{ tagName: 'INPUT', id: 70, type: 'text' }", true), ("{ tagName: 'INPUT', id: 71, type: 'search' }", true),
                      ("{ tagName: 'TEXTAREA', id: 72 }", true), ("{ tagName: 'DIV', id: 73, isContentEditable: true }", true),
                      ("{ tagName: 'BUTTON', id: 74 }", false), ("{ tagName: 'A', id: 75 }", false),
                      ("{ tagName: 'DIV', id: 76, tabIndex: 0, isContentEditable: false }", false),
                      ("{ tagName: 'DIV', id: 77, role: 'textbox' }", false), ("{ tagName: 'INPUT', id: 78, type: 'checkbox' }", false),
                      ("{ tagName: 'SELECT', id: 79 }", false)])
    func focusKinds(element: String, ordinary: Bool) async throws {
        let stack = await Self.stack()
        stack.page.run("document.activeElement = \(element);")
        let focus = await WebControls(tabs: stack.tabs).focusedField(in: stack.processID)
        if ordinary {
            guard case .ordinary(let identity) = focus else { Issue.record("\(element): \(focus)"); return }
            #expect(identity.token.contains("target-1"))
        } else {
            #expect(focus == .unknown, "\(element): an ARIA role or a focus alone attests no field")
        }
    }

    // MARK: The engine on the web roles

    @Test("classify: the password field is secure, the text field ordinary and bound to its node")
    func classify() async throws {
        let stack = await Self.stack()
        #expect(await stack.engine.classify(Self.typing("x", into: "Accesso", in: stack)) == .secure)
        let nome = await stack.engine.classify(Self.typing("Grace", into: "Nome", in: stack))
        let binding = try #require(nome.binding, "\(nome)")
        #expect(binding.identity.token.hasSuffix("|12") && binding.role == "AXTextField" && binding.label == "Nome")
    }

    @Test("a node replaced between classification and dispatch, same name, role and place, is refused: nothing typed",
          arguments: ["text", "password"])
    func replacedBeforeDispatch(type: String) async throws {
        let stack = await Self.stack()
        let binding = try #require(await stack.engine.classify(Self.typing("Grace", into: "Nome", in: stack)).binding)
        stack.page.change([.replace(12, by: 52, type: type)])
        let outcome = await stack.engine.deliver(Self.typing("Grace", into: "Nome", in: stack, binding: binding))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(stack.page.value(of: 52) == "", "the new node holds nothing typed")
    }

    @Test("the field becomes a password field after the click: the click stands, no key reaches it")
    func typeFlipsAfterTheClick() async throws {
        let stack = await Self.stack()
        let binding = try #require(await stack.engine.classify(Self.typing("Grace", into: "Nome", in: stack)).binding)
        stack.page.schedule(afterPress: [.setType(12, "password")])
        let outcome = await stack.engine.deliver(Self.typing("Grace", into: "Nome", in: stack, binding: binding))
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("nothing was typed"), Comment(rawValue: outcome.message))
        #expect(stack.page.value(of: 12) == "Ada", "no key went out")
    }

    @Test("bound and unchanged: the text reaches the field and reads back")
    func boundAndCoherent() async throws {
        let stack = await Self.stack()
        let binding = try #require(await stack.engine.classify(Self.typing("Grace", into: "Nome", in: stack)).binding)
        let outcome = await stack.engine.deliver(Self.typing("Grace", into: "Nome", in: stack, binding: binding))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(stack.page.value(of: 12) == "Grace")
    }
}
