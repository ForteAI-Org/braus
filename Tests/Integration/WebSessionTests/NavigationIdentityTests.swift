import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W11: an action reaches only the document its scene was read from. A navigation or a reload between the scene and
/// the dispatch is another document, and the web actuator sends nothing to it: the engine refuses, nothing sent. Over
/// `SyntheticPage`, whose `navigate` change replaces the document, with the production web roles.
@Suite("Acting on the document that was read (W11)")
struct NavigationIdentityTests {

    static func stack() async -> SyntheticForm.Stack {
        await SyntheticForm.stack()
    }

    private static func click(_ target: String, _ stack: SyntheticForm.Stack) async -> ActOutcome {
        await stack.engine.act(ActionRequest(processID: stack.processID, bundleID: "web:fixture.test", appName: "fixture.test",
                                             target: target, verb: .click))
    }

    @Test("a navigation after the scene was read: the click is refused, nothing was sent, no press reached the page")
    func clickAfterNavigation() async throws {
        let stack = await Self.stack()
        stack.page.schedule([.navigate], afterScene: 1)
        let outcome = await Self.click("Nome", stack)
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was sent"), Comment(rawValue: outcome.message))
        #expect(stack.page.pressCount == 0)
    }

    @Test("a key pressed after a navigation since the scene: refused, no key reached the page")
    func keyAfterNavigation() async throws {
        let stack = await Self.stack()
        stack.page.schedule([.navigate], afterScene: 1)
        let outcome = await stack.engine.deliver(InputRequest(processID: stack.processID, bundleID: "web:fixture.test",
                                                              appName: "fixture.test",
                                                              input: .pressKey(KeyChord(.character("x")), times: 1)))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(stack.page.textCount == 0)
    }

    @Test("the same document: the click goes out as before (positive control)")
    func sameDocument() async throws {
        let stack = await Self.stack()
        let outcome = await Self.click("Nome", stack)
        #expect(outcome.kind != .refused, Comment(rawValue: outcome.message))
        #expect(stack.page.pressCount == 1)
    }
}
